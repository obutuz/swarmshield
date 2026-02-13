defmodule Swarmshield.Deliberation do
  @moduledoc """
  The Deliberation context manages AnalysisSession, AgentInstance,
  DeliberationMessage, and Verdict CRUD operations.

  All operations are workspace-scoped. PubSub broadcasts on session
  status changes for real-time LiveView updates.
  """

  import Ecto.Query, warn: false
  alias Swarmshield.Repo

  alias Swarmshield.Accounts
  alias Swarmshield.Deliberation.{AgentInstance, AnalysisSession, DeliberationMessage, Verdict}

  @default_page_size 50
  @max_page_size 100

  @valid_session_transitions %{
    pending: [:analyzing, :failed],
    analyzing: [:deliberating, :voting, :failed, :timed_out],
    deliberating: [:voting, :failed, :timed_out],
    voting: [:completed, :failed, :timed_out],
    completed: [],
    failed: [],
    timed_out: []
  }

  # ---------------------------------------------------------------------------
  # AnalysisSession
  # ---------------------------------------------------------------------------

  def list_analysis_sessions(workspace_id, opts \\ [])

  def list_analysis_sessions(workspace_id, opts) when is_binary(workspace_id) do
    {_page, page_size, offset} = pagination_params(opts)

    base_query =
      from(s in AnalysisSession,
        where: s.workspace_id == ^workspace_id,
        preload: [:verdict, workflow: :ghost_protocol_config]
      )
      |> apply_session_filters(opts)

    total_count = Repo.aggregate(base_query, :count)

    sessions =
      base_query
      |> order_by([s], desc: s.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {sessions, total_count}
  end

  def get_analysis_session!(id) when is_binary(id) do
    AnalysisSession
    |> Repo.get!(id)
    |> Repo.preload(agent_instances: :deliberation_messages, verdict: [])
  end

  def get_analysis_session_for_workspace!(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    AnalysisSession
    |> where([s], s.id == ^id and s.workspace_id == ^workspace_id)
    |> Repo.one!()
    |> Repo.preload(agent_instances: :deliberation_messages, verdict: [])
  end

  @doc """
  Gets a full analysis session for the detail view, scoped to workspace.

  Returns nil if not found. Preloads all associations needed for the
  deliberation show view: agent instances with definitions and messages,
  verdict, workflow with ghost_protocol_config.
  """
  def get_full_session_for_workspace(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    AnalysisSession
    |> where([s], s.id == ^id and s.workspace_id == ^workspace_id)
    |> Repo.one()
    |> case do
      nil ->
        nil

      session ->
        Repo.preload(session,
          verdict: [],
          workflow: :ghost_protocol_config,
          agent_instances: [:agent_definition, :deliberation_messages]
        )
    end
  end

  @doc """
  Gets a session with list-view preloads, scoped to workspace.
  Returns nil if not found. Used by PubSub handlers in DeliberationsLive.
  """
  def get_session_for_list(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    AnalysisSession
    |> where([s], s.id == ^id and s.workspace_id == ^workspace_id)
    |> Repo.one()
    |> case do
      nil -> nil
      session -> Repo.preload(session, [:verdict, workflow: :ghost_protocol_config])
    end
  end

  @doc """
  Gets the analysis session linked to an agent event, if any.
  Returns nil if no session is linked. Preloads verdict and workflow.
  """
  def get_session_for_event(event_id) when is_binary(event_id) do
    AnalysisSession
    |> where([s], s.agent_event_id == ^event_id)
    |> Repo.one()
    |> case do
      nil ->
        nil

      session ->
        Repo.preload(session, [
          :verdict,
          workflow: :ghost_protocol_config,
          agent_instances: :agent_definition
        ])
    end
  end

  def create_analysis_session(attrs) when is_map(attrs) do
    result =
      %AnalysisSession{}
      |> AnalysisSession.changeset(attrs)
      |> maybe_set_server_fields(attrs)
      |> Repo.insert()

    case result do
      {:ok, session} ->
        broadcast_session_change(session, :session_created)
        audit_session_lifecycle(session, "deliberation.session_created")
        {:ok, session}

      error ->
        error
    end
  end

  def update_analysis_session(%AnalysisSession{} = session, attrs) when is_map(attrs) do
    new_status = Map.get(attrs, :status) || Map.get(attrs, "status")

    with :ok <- validate_session_transition(session.status, new_status) do
      result =
        session
        |> AnalysisSession.status_changeset(attrs)
        |> Repo.update()

      case result do
        {:ok, updated} ->
          broadcast_session_change(updated, :session_updated)
          maybe_audit_terminal_status(updated, new_status)
          {:ok, updated}

        error ->
          error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # AgentInstance
  # ---------------------------------------------------------------------------

  def list_agent_instances(session_id) when is_binary(session_id) do
    from(ai in AgentInstance,
      where: ai.analysis_session_id == ^session_id,
      preload: [:agent_definition],
      order_by: [asc: ai.inserted_at]
    )
    |> Repo.all()
  end

  def list_agent_instances_by_ids(ids) when is_list(ids) do
    from(ai in AgentInstance,
      where: ai.id in ^ids,
      preload: [:agent_definition],
      order_by: [asc: ai.inserted_at]
    )
    |> Repo.all()
  end

  def get_agent_instance!(id) when is_binary(id) do
    AgentInstance
    |> Repo.get!(id)
    |> Repo.preload([:agent_definition, :deliberation_messages])
  end

  def create_agent_instance(attrs) when is_map(attrs) do
    %AgentInstance{}
    |> AgentInstance.changeset(attrs)
    |> maybe_set_instance_fks(attrs)
    |> Repo.insert()
  end

  def update_agent_instance(%AgentInstance{} = instance, attrs) when is_map(attrs) do
    instance
    |> AgentInstance.changeset(attrs)
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # DeliberationMessage
  # ---------------------------------------------------------------------------

  def create_deliberation_message(attrs) when is_map(attrs) do
    result =
      %DeliberationMessage{}
      |> DeliberationMessage.changeset(attrs)
      |> maybe_set_message_fks(attrs)
      |> Repo.insert()

    case result do
      {:ok, message} ->
        broadcast_message(message)
        {:ok, message}

      error ->
        error
    end
  end

  @doc """
  Gets a single deliberation message by ID.

  Returns nil if not found. Preloads agent_instance with agent_definition
  for use in real-time PubSub updates where agent_name is needed.
  """
  def get_deliberation_message(id) when is_binary(id) do
    DeliberationMessage
    |> Repo.get(id)
    |> case do
      nil -> nil
      message -> Repo.preload(message, agent_instance: :agent_definition)
    end
  end

  def list_messages_by_session(session_id) when is_binary(session_id) do
    from(m in DeliberationMessage,
      where: m.analysis_session_id == ^session_id,
      preload: [agent_instance: :agent_definition],
      order_by: [asc: m.round, asc: m.inserted_at]
    )
    |> Repo.all()
  end

  def list_messages_by_instance(instance_id) when is_binary(instance_id) do
    from(m in DeliberationMessage,
      where: m.agent_instance_id == ^instance_id,
      order_by: [asc: m.round, asc: m.inserted_at]
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Verdict
  # ---------------------------------------------------------------------------

  def create_verdict(attrs) when is_map(attrs) do
    result =
      %Verdict{}
      |> Verdict.create_changeset(attrs)
      |> maybe_set_verdict_fk(attrs)
      |> Repo.insert()

    case result do
      {:ok, verdict} ->
        broadcast_verdict(verdict)
        {:ok, verdict}

      error ->
        error
    end
  end

  def get_verdict_by_session(session_id) when is_binary(session_id) do
    Repo.get_by(Verdict, analysis_session_id: session_id)
  end

  # ---------------------------------------------------------------------------
  # Aggregates (database-level, not Enum)
  # ---------------------------------------------------------------------------

  def session_token_totals(session_id) when is_binary(session_id) do
    from(ai in AgentInstance,
      where: ai.analysis_session_id == ^session_id,
      select: %{
        total_tokens: coalesce(sum(ai.tokens_used), 0),
        total_cost_cents: coalesce(sum(ai.cost_cents), 0)
      }
    )
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  def subscribe_to_session(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberation:#{session_id}")
  end

  def subscribe_to_workspace_deliberations(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberations:#{workspace_id}")
  end

  @terminal_statuses [:completed, :failed, :timed_out]

  defp maybe_audit_terminal_status(session, status) when status in @terminal_statuses do
    audit_session_lifecycle(session, "deliberation.session_#{status}")
  end

  defp maybe_audit_terminal_status(_session, _status), do: :ok

  defp broadcast_session_change(%AnalysisSession{} = session, event) do
    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "deliberations:#{session.workspace_id}",
      {event, session.id, session.status}
    )

    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "deliberation:#{session.id}",
      {event, session.id, session.status}
    )
  end

  defp broadcast_message(%DeliberationMessage{} = message) do
    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "deliberation:#{message.analysis_session_id}",
      {:message_created, message.id, message.message_type}
    )
  end

  defp broadcast_verdict(%Verdict{} = verdict) do
    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "deliberation:#{verdict.analysis_session_id}",
      {:verdict_reached, verdict.id, verdict.decision}
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_session_transition(_current, nil), do: :ok

  defp validate_session_transition(current, new) when is_atom(current) and is_atom(new) do
    allowed = Map.get(@valid_session_transitions, current, [])

    case new in allowed do
      true -> :ok
      false -> {:error, "cannot transition from #{current} to #{new}"}
    end
  end

  defp validate_session_transition(current, new) when is_binary(new) do
    validate_session_transition(current, String.to_existing_atom(new))
  rescue
    ArgumentError -> {:error, "invalid status: #{new}"}
  end

  defp maybe_set_server_fields(changeset, attrs) do
    changeset
    |> maybe_put_fk(:workspace_id, attrs)
    |> maybe_put_fk(:workflow_id, attrs)
    |> maybe_put_fk(:consensus_policy_id, attrs)
    |> maybe_put_fk(:agent_event_id, attrs)
    |> maybe_put_field(:expires_at, attrs)
    |> maybe_put_field(:input_content_hash, attrs)
  end

  defp maybe_put_field(changeset, key, attrs) do
    case Map.get(attrs, key) || Map.get(attrs, to_string(key)) do
      nil -> changeset
      value -> Ecto.Changeset.put_change(changeset, key, value)
    end
  end

  defp maybe_set_instance_fks(changeset, attrs) do
    changeset
    |> maybe_put_fk(:analysis_session_id, attrs)
    |> maybe_put_fk(:agent_definition_id, attrs)
  end

  defp maybe_set_message_fks(changeset, attrs) do
    changeset
    |> maybe_put_fk(:analysis_session_id, attrs)
    |> maybe_put_fk(:agent_instance_id, attrs)
  end

  defp maybe_set_verdict_fk(changeset, attrs) do
    maybe_put_fk(changeset, :analysis_session_id, attrs)
  end

  defp maybe_put_fk(changeset, key, attrs) do
    value = Map.get(attrs, key) || Map.get(attrs, to_string(key))

    case value do
      nil -> changeset
      val -> Ecto.Changeset.change(changeset, %{key => val})
    end
  end

  defp audit_session_lifecycle(%AnalysisSession{} = session, action) do
    Task.Supervisor.start_child(Swarmshield.TaskSupervisor, fn ->
      session_id = session.id
      workspace_id = session.workspace_id
      status = session.status

      try do
        Accounts.create_audit_entry(%{
          action: action,
          resource_type: "analysis_session",
          resource_id: session_id,
          workspace_id: workspace_id,
          metadata: %{"status" => to_string(status)}
        })
      catch
        _kind, _reason -> :ok
      end
    end)
  end

  defp apply_session_filters(query, opts) do
    query
    |> maybe_filter_session_status(Keyword.get(opts, :status))
    |> maybe_filter_session_trigger(Keyword.get(opts, :trigger))
    |> maybe_filter_session_from(Keyword.get(opts, :from))
    |> maybe_filter_session_to(Keyword.get(opts, :to))
  end

  # ---------------------------------------------------------------------------
  # Dashboard Stats (conditional aggregates - single query)
  # ---------------------------------------------------------------------------

  @doc """
  Returns deliberation dashboard statistics for a workspace.

  Single query with conditional aggregates:
  - active_deliberations: sessions in pending/analyzing/deliberating/voting
  - verdicts_today: completed sessions with verdict from today

  Returns a map with integer values.
  """
  def get_dashboard_stats(workspace_id) when is_binary(workspace_id) do
    today_start = DateTime.utc_now(:second) |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])

    active_statuses = [:pending, :analyzing, :deliberating, :voting]

    from(s in AnalysisSession,
      where: s.workspace_id == ^workspace_id,
      select: %{
        active_deliberations: count(s.id) |> filter(s.status in ^active_statuses),
        verdicts_today:
          count(s.id) |> filter(s.status == :completed and s.completed_at >= ^today_start)
      }
    )
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp maybe_filter_session_status(query, nil), do: query
  defp maybe_filter_session_status(query, status), do: where(query, [s], s.status == ^status)

  defp maybe_filter_session_trigger(query, nil), do: query
  defp maybe_filter_session_trigger(query, trigger), do: where(query, [s], s.trigger == ^trigger)

  defp maybe_filter_session_from(query, nil), do: query

  defp maybe_filter_session_from(query, %DateTime{} = from),
    do: where(query, [s], s.inserted_at >= ^from)

  defp maybe_filter_session_to(query, nil), do: query

  defp maybe_filter_session_to(query, %DateTime{} = to),
    do: where(query, [s], s.inserted_at <= ^to)

  defp pagination_params(opts) do
    page = opts |> Keyword.get(:page, 1) |> max(1)

    page_size =
      opts |> Keyword.get(:page_size, @default_page_size) |> min(@max_page_size) |> max(1)

    offset = (page - 1) * page_size
    {page, page_size, offset}
  end
end
