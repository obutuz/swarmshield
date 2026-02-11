defmodule Swarmshield.Workflows do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Swarmshield.Accounts
  alias Swarmshield.Deliberation.{ConsensusPolicy, Workflow, WorkflowStep}
  alias Swarmshield.Repo

  @default_page_size 50
  @max_page_size 100

  # ---------------------------------------------------------------------------
  # Workflow
  # ---------------------------------------------------------------------------

  def list_workflows(workspace_id, opts \\ [])

  def list_workflows(workspace_id, opts) when is_binary(workspace_id) do
    {_page, page_size, offset} = pagination_params(opts)

    base_query =
      from(w in Workflow,
        where: w.workspace_id == ^workspace_id,
        preload: [:workflow_steps, :ghost_protocol_config]
      )

    total_count = Repo.aggregate(base_query, :count)

    workflows =
      base_query
      |> order_by([w], desc: w.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {workflows, total_count}
  end

  def get_workflow!(id) when is_binary(id) do
    Workflow
    |> Repo.get!(id)
    |> Repo.preload(workflow_steps: :agent_definition, ghost_protocol_config: [])
  end

  @doc """
  Finds the first enabled workflow matching a trigger condition for a workspace.

  Matches workflows where `trigger_on` equals the given trigger or `:all`.
  Returns the first match ordered by `inserted_at ASC` (oldest = highest priority),
  or `nil` if no matching workflow exists.
  """
  def find_matching_workflow(workspace_id, trigger)
      when is_binary(workspace_id) and is_atom(trigger) do
    from(w in Workflow,
      where:
        w.workspace_id == ^workspace_id and
          w.enabled == true and
          w.trigger_on in ^[trigger, :all],
      order_by: [asc: w.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  def create_workflow(workspace_id, attrs)
      when is_binary(workspace_id) and is_map(attrs) do
    result =
      %Workflow{workspace_id: workspace_id}
      |> Workflow.changeset(attrs)
      |> maybe_put_fk(:ghost_protocol_config_id, attrs)
      |> Repo.insert()

    case result do
      {:ok, workflow} ->
        audit_async("workflow.created", "workflow", workflow.id, workspace_id)
        {:ok, workflow}

      error ->
        error
    end
  end

  def update_workflow(%Workflow{} = workflow, attrs) when is_map(attrs) do
    result =
      workflow
      |> Workflow.changeset(attrs)
      |> maybe_put_fk(:ghost_protocol_config_id, attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        audit_async("workflow.updated", "workflow", updated.id, updated.workspace_id)
        {:ok, updated}

      error ->
        error
    end
  end

  def delete_workflow(%Workflow{} = workflow) do
    workflow_id = workflow.id
    workspace_id = workflow.workspace_id

    case Repo.delete(workflow) do
      {:ok, deleted} ->
        audit_async("workflow.deleted", "workflow", workflow_id, workspace_id)
        {:ok, deleted}

      error ->
        error
    end
  end

  def get_enabled_workflow_for_trigger(workspace_id, trigger_type)
      when is_binary(workspace_id) and is_atom(trigger_type) do
    from(w in Workflow,
      where:
        w.workspace_id == ^workspace_id and
          w.enabled == true and
          w.trigger_on in ^[trigger_type, :all],
      order_by: [asc: w.inserted_at],
      limit: 1
    )
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
  # WorkflowStep
  # ---------------------------------------------------------------------------

  def list_workflow_steps(workflow_id) when is_binary(workflow_id) do
    from(s in WorkflowStep,
      where: s.workflow_id == ^workflow_id,
      preload: [:agent_definition],
      order_by: [asc: s.position]
    )
    |> Repo.all()
  end

  def create_workflow_step(attrs) when is_map(attrs) do
    result =
      %WorkflowStep{}
      |> WorkflowStep.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, step} ->
        step = Repo.preload(step, :agent_definition)
        workflow = Repo.get!(Workflow, step.workflow_id)
        audit_async("workflow_step.created", "workflow_step", step.id, workflow.workspace_id)
        {:ok, step}

      error ->
        error
    end
  end

  def update_workflow_step(%WorkflowStep{} = step, attrs) when is_map(attrs) do
    result =
      step
      |> WorkflowStep.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        updated = Repo.preload(updated, :agent_definition)
        workflow = Repo.get!(Workflow, updated.workflow_id)

        audit_async(
          "workflow_step.updated",
          "workflow_step",
          updated.id,
          workflow.workspace_id
        )

        {:ok, updated}

      error ->
        error
    end
  end

  def delete_workflow_step(%WorkflowStep{} = step) do
    step_id = step.id
    workflow_id = step.workflow_id

    case Repo.delete(step) do
      {:ok, deleted} ->
        workflow = Repo.get!(Workflow, workflow_id)
        audit_async("workflow_step.deleted", "workflow_step", step_id, workflow.workspace_id)
        {:ok, deleted}

      error ->
        error
    end
  end

  def reorder_workflow_steps(workflow_id, ordered_ids)
      when is_binary(workflow_id) and is_list(ordered_ids) do
    existing_ids =
      from(s in WorkflowStep,
        where: s.workflow_id == ^workflow_id,
        select: s.id
      )
      |> Repo.all()
      |> MapSet.new()

    requested_ids = MapSet.new(ordered_ids)

    case MapSet.equal?(existing_ids, requested_ids) do
      false ->
        {:error, :ids_mismatch}

      true ->
        position_map =
          ordered_ids
          |> Enum.with_index(1)
          |> Map.new()

        multi =
          Multi.new()
          |> Multi.update_all(
            :clear_positions,
            from(s in WorkflowStep,
              where: s.workflow_id == ^workflow_id,
              update: [set: [position: fragment("- ?", s.position)]]
            ),
            []
          )
          |> then(fn multi ->
            Enum.reduce(position_map, multi, fn {step_id, position}, acc ->
              Multi.update_all(
                acc,
                {:set_position, step_id},
                from(s in WorkflowStep,
                  where: s.id == ^step_id and s.workflow_id == ^workflow_id,
                  update: [set: [position: ^position]]
                ),
                []
              )
            end)
          end)

        case Repo.transaction(multi) do
          {:ok, _results} ->
            workflow = Repo.get!(Workflow, workflow_id)

            audit_async(
              "workflow_steps.reordered",
              "workflow",
              workflow_id,
              workflow.workspace_id
            )

            {:ok, list_workflow_steps(workflow_id)}

          {:error, failed_op, failed_value, _changes} ->
            {:error, {failed_op, failed_value}}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # ConsensusPolicy
  # ---------------------------------------------------------------------------

  def list_consensus_policies(workspace_id, opts \\ [])

  def list_consensus_policies(workspace_id, opts) when is_binary(workspace_id) do
    {_page, page_size, offset} = pagination_params(opts)

    base_query =
      from(cp in ConsensusPolicy,
        where: cp.workspace_id == ^workspace_id
      )

    total_count = Repo.aggregate(base_query, :count)

    policies =
      base_query
      |> order_by([cp], desc: cp.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {policies, total_count}
  end

  def get_consensus_policy!(id) when is_binary(id) do
    Repo.get!(ConsensusPolicy, id)
  end

  def create_consensus_policy(workspace_id, attrs)
      when is_binary(workspace_id) and is_map(attrs) do
    result =
      %ConsensusPolicy{workspace_id: workspace_id}
      |> ConsensusPolicy.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, policy} ->
        audit_async("consensus_policy.created", "consensus_policy", policy.id, workspace_id)
        {:ok, policy}

      error ->
        error
    end
  end

  def update_consensus_policy(%ConsensusPolicy{} = policy, attrs) when is_map(attrs) do
    result =
      policy
      |> ConsensusPolicy.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        audit_async(
          "consensus_policy.updated",
          "consensus_policy",
          updated.id,
          updated.workspace_id
        )

        {:ok, updated}

      error ->
        error
    end
  end

  def delete_consensus_policy(%ConsensusPolicy{} = policy) do
    policy_id = policy.id
    workspace_id = policy.workspace_id

    case Repo.delete(policy) do
      {:ok, deleted} ->
        audit_async("consensus_policy.deleted", "consensus_policy", policy_id, workspace_id)
        {:ok, deleted}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp audit_async(action, resource_type, resource_id, workspace_id) do
    Task.Supervisor.start_child(Swarmshield.TaskSupervisor, fn ->
      try do
        Accounts.create_audit_entry(%{
          action: action,
          resource_type: resource_type,
          resource_id: resource_id,
          workspace_id: workspace_id,
          metadata: %{}
        })
      catch
        _kind, _reason -> :ok
      end
    end)
  end

  defp maybe_put_fk(changeset, key, attrs) do
    value = Map.get(attrs, key) || Map.get(attrs, to_string(key))

    case value do
      nil -> changeset
      val -> Ecto.Changeset.change(changeset, %{key => val})
    end
  end

  defp pagination_params(opts) do
    page = opts |> Keyword.get(:page, 1) |> max(1)

    page_size =
      opts |> Keyword.get(:page_size, @default_page_size) |> min(@max_page_size) |> max(1)

    offset = (page - 1) * page_size
    {page, page_size, offset}
  end
end
