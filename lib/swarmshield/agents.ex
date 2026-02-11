defmodule Swarmshield.Agents do
  @moduledoc """
  The Agents context manages AgentDefinition and PromptTemplate CRUD.

  All operations are workspace-scoped. Audit entries are created
  asynchronously via Task.Supervisor for every mutation.
  """

  import Ecto.Query, warn: false
  alias Swarmshield.Repo

  alias Swarmshield.Accounts
  alias Swarmshield.Deliberation.{AgentDefinition, PromptTemplate, WorkflowStep}

  @default_page_size 50
  @max_page_size 100

  # ---------------------------------------------------------------------------
  # AgentDefinition
  # ---------------------------------------------------------------------------

  def list_agent_definitions(workspace_id, opts \\ [])

  def list_agent_definitions(workspace_id, opts) when is_binary(workspace_id) do
    {_page, page_size, offset} = pagination_params(opts)

    base_query =
      from(ad in AgentDefinition, where: ad.workspace_id == ^workspace_id)
      |> apply_agent_definition_filters(opts)

    total_count = Repo.aggregate(base_query, :count)

    results =
      base_query
      |> order_by([ad], desc: ad.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {results, total_count}
  end

  def get_agent_definition!(id) when is_binary(id) do
    Repo.get!(AgentDefinition, id)
  end

  def create_agent_definition(workspace_id, attrs)
      when is_binary(workspace_id) and is_map(attrs) do
    result =
      %AgentDefinition{workspace_id: workspace_id}
      |> AgentDefinition.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, definition} ->
        audit_change(definition, "agents.definition_created", workspace_id)
        {:ok, definition}

      error ->
        error
    end
  end

  def update_agent_definition(%AgentDefinition{} = definition, attrs) when is_map(attrs) do
    result =
      definition
      |> AgentDefinition.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        audit_change(updated, "agents.definition_updated", updated.workspace_id)
        {:ok, updated}

      error ->
        error
    end
  end

  def delete_agent_definition(%AgentDefinition{} = definition) do
    case has_workflow_steps?(:agent_definition_id, definition.id) do
      true ->
        {:error, :has_workflow_steps}

      false ->
        result = Repo.delete(definition)

        case result do
          {:ok, deleted} ->
            audit_change(deleted, "agents.definition_deleted", deleted.workspace_id)
            {:ok, deleted}

          error ->
            error
        end
    end
  end

  def list_enabled_agent_definitions(workspace_id) when is_binary(workspace_id) do
    from(ad in AgentDefinition,
      where: ad.workspace_id == ^workspace_id and ad.enabled == true,
      order_by: [asc: ad.name]
    )
    |> Repo.all()
  end

  @doc "Returns {id, name} tuples of enabled agent definitions for select dropdowns."
  def list_enabled_agent_definitions_for_select(workspace_id) when is_binary(workspace_id) do
    from(ad in AgentDefinition,
      where: ad.workspace_id == ^workspace_id and ad.enabled == true,
      order_by: [asc: ad.name],
      select: {ad.id, ad.name}
    )
    |> Repo.all()
  end

  @doc "Checks if an agent definition belongs to the given workspace."
  def workspace_agent_definition?(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    from(ad in AgentDefinition, where: ad.id == ^id and ad.workspace_id == ^workspace_id)
    |> Repo.exists?()
  end

  # ---------------------------------------------------------------------------
  # PromptTemplate
  # ---------------------------------------------------------------------------

  def list_prompt_templates(workspace_id, opts \\ [])

  def list_prompt_templates(workspace_id, opts) when is_binary(workspace_id) do
    {_page, page_size, offset} = pagination_params(opts)

    base_query =
      from(pt in PromptTemplate, where: pt.workspace_id == ^workspace_id)
      |> apply_prompt_template_filters(opts)

    total_count = Repo.aggregate(base_query, :count)

    results =
      base_query
      |> order_by([pt], desc: pt.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {results, total_count}
  end

  def get_prompt_template!(id) when is_binary(id) do
    Repo.get!(PromptTemplate, id)
  end

  def create_prompt_template(workspace_id, attrs)
      when is_binary(workspace_id) and is_map(attrs) do
    result =
      %PromptTemplate{workspace_id: workspace_id}
      |> PromptTemplate.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, template} ->
        audit_change(template, "agents.template_created", workspace_id)
        {:ok, template}

      error ->
        error
    end
  end

  def update_prompt_template(%PromptTemplate{} = template, attrs) when is_map(attrs) do
    result =
      template
      |> PromptTemplate.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        audit_change(updated, "agents.template_updated", updated.workspace_id)
        {:ok, updated}

      error ->
        error
    end
  end

  @doc "Returns {id, name} tuples of enabled prompt templates for select dropdowns."
  def list_enabled_prompt_templates_for_select(workspace_id) when is_binary(workspace_id) do
    from(pt in PromptTemplate,
      where: pt.workspace_id == ^workspace_id and pt.enabled == true,
      order_by: [asc: pt.name],
      select: {pt.id, pt.name}
    )
    |> Repo.all()
  end

  @doc "Checks if a prompt template belongs to the given workspace."
  def workspace_prompt_template?(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    from(pt in PromptTemplate, where: pt.id == ^id and pt.workspace_id == ^workspace_id)
    |> Repo.exists?()
  end

  def delete_prompt_template(%PromptTemplate{} = template) do
    case has_workflow_steps?(:prompt_template_id, template.id) do
      true ->
        {:error, :has_workflow_steps}

      false ->
        result = Repo.delete(template)

        case result do
          {:ok, deleted} ->
            audit_change(deleted, "agents.template_deleted", deleted.workspace_id)
            {:ok, deleted}

          error ->
            error
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private - Referential Integrity
  # ---------------------------------------------------------------------------

  defp has_workflow_steps?(fk_column, id) when is_atom(fk_column) and is_binary(id) do
    from(ws in WorkflowStep, where: field(ws, ^fk_column) == ^id, select: true, limit: 1)
    |> Repo.exists?()
  end

  # ---------------------------------------------------------------------------
  # Private - Filters
  # ---------------------------------------------------------------------------

  defp apply_agent_definition_filters(query, opts) do
    query
    |> maybe_filter_enabled(Keyword.get(opts, :enabled))
    |> maybe_filter_search(Keyword.get(opts, :search))
  end

  defp apply_prompt_template_filters(query, opts) do
    query
    |> maybe_filter_enabled(Keyword.get(opts, :enabled))
    |> maybe_filter_category(Keyword.get(opts, :category))
  end

  defp maybe_filter_enabled(query, nil), do: query
  defp maybe_filter_enabled(query, enabled), do: where(query, [r], r.enabled == ^enabled)

  defp maybe_filter_search(query, nil), do: query
  defp maybe_filter_search(query, ""), do: query

  defp maybe_filter_search(query, search) when is_binary(search) do
    term = "%#{search}%"
    where(query, [ad], ilike(ad.name, ^term) or ilike(ad.role, ^term))
  end

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, category), do: where(query, [pt], pt.category == ^category)

  # ---------------------------------------------------------------------------
  # Private - Audit
  # ---------------------------------------------------------------------------

  defp audit_change(record, action, workspace_id) do
    resource_id = record.id
    resource_type = resource_type_for(record)

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

  defp resource_type_for(%AgentDefinition{}), do: "agent_definition"
  defp resource_type_for(%PromptTemplate{}), do: "prompt_template"

  # ---------------------------------------------------------------------------
  # Private - Pagination
  # ---------------------------------------------------------------------------

  defp pagination_params(opts) do
    page = opts |> Keyword.get(:page, 1) |> max(1)

    page_size =
      opts |> Keyword.get(:page_size, @default_page_size) |> min(@max_page_size) |> max(1)

    offset = (page - 1) * page_size
    {page, page_size, offset}
  end
end
