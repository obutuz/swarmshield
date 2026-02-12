defmodule Swarmshield.Gateway do
  @moduledoc """
  The Gateway context manages RegisteredAgent and AgentEvent CRUD operations.

  This is the ingestion layer for SwarmShield. External AI agents authenticate
  via API keys, and their actions/outputs are captured as AgentEvents. All
  operations are workspace-scoped for multi-tenant isolation.
  """

  require Logger

  import Ecto.Query, warn: false
  alias Swarmshield.Repo

  alias Swarmshield.Accounts
  alias Swarmshield.Deliberation.Session, as: DeliberationSession
  alias Swarmshield.Gateway.{AgentEvent, RegisteredAgent}
  alias Swarmshield.Policies
  alias Swarmshield.Policies.PolicyEngine
  alias Swarmshield.Workflows

  @default_page_size 50
  @max_page_size 100

  # Valid status transitions for agent events.
  # pending -> allowed | flagged | blocked (terminal states from policy evaluation)
  @valid_event_status_transitions %{
    pending: [:allowed, :flagged, :blocked]
  }

  # ---------------------------------------------------------------------------
  # RegisteredAgent
  # ---------------------------------------------------------------------------

  @doc """
  Lists registered agents for a workspace.

  Uses LEFT JOIN with aggregate for event count (not N+1 Enum.count).
  Returns `{agents, total_count}`.

  ## Options

    * `:status` - filter by agent status atom
    * `:agent_type` - filter by agent type atom
    * `:search` - search by name (case-insensitive ILIKE)
    * `:page` - page number (default 1)
    * `:page_size` - items per page (default 50, max 100)
  """
  def list_registered_agents(workspace_id, opts \\ [])

  def list_registered_agents(workspace_id, opts) when is_binary(workspace_id) do
    {_page, page_size, offset} = pagination_params(opts)

    base_query =
      from(a in RegisteredAgent,
        where: a.workspace_id == ^workspace_id
      )
      |> apply_agent_filters(opts)

    total_count = Repo.aggregate(base_query, :count)

    agents =
      base_query
      |> order_by([a], desc: a.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {agents, total_count}
  end

  @doc """
  Gets a single registered agent by ID.

  Raises `Ecto.NoResultsError` if not found.
  """
  def get_registered_agent!(id) when is_binary(id) do
    Repo.get!(RegisteredAgent, id)
  end

  @doc """
  Gets a single registered agent by ID, scoped to a workspace.

  Returns `nil` if not found or agent belongs to a different workspace.
  """
  def get_registered_agent_for_workspace(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    RegisteredAgent
    |> where([a], a.id == ^id and a.workspace_id == ^workspace_id)
    |> Repo.one()
  end

  @doc """
  Returns aggregate stats for a single agent using conditional aggregates.

  Returns a map with:
  - `:total_events` - total event count
  - `:flagged_count` - events with status :flagged
  - `:blocked_count` - events with status :blocked
  """
  def get_agent_stats(agent_id) when is_binary(agent_id) do
    from(e in AgentEvent,
      where: e.registered_agent_id == ^agent_id,
      select: %{
        total_events: count(e.id),
        flagged_count: count(e.id) |> filter(e.status == :flagged),
        blocked_count: count(e.id) |> filter(e.status == :blocked)
      }
    )
    |> Repo.one()
  end

  @doc """
  Gets a registered agent by API key hash.

  Uses the unique index on `api_key_hash` for efficient lookup.
  Returns `nil` if no agent matches the hash.
  """
  def get_registered_agent_by_api_key(api_key_hash) when is_binary(api_key_hash) do
    Repo.get_by(RegisteredAgent, api_key_hash: api_key_hash)
  end

  def get_registered_agent_by_api_key(_), do: nil

  @doc """
  Creates a registered agent with a generated API key.

  Returns `{:ok, agent, raw_api_key}` on success, where `raw_api_key` is the
  plaintext key shown once to the user. The hash and prefix are stored in the DB.

  `workspace_id` is set server-side (never from user input).
  """
  def create_registered_agent(workspace_id, attrs) when is_binary(workspace_id) do
    {raw_key, hash, prefix} = RegisteredAgent.generate_api_key()

    result =
      %RegisteredAgent{workspace_id: workspace_id}
      |> RegisteredAgent.changeset(attrs)
      |> Ecto.Changeset.change(%{api_key_hash: hash, api_key_prefix: prefix})
      |> Repo.insert()

    case result do
      {:ok, agent} -> {:ok, agent, raw_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Updates a registered agent's user-facing fields.

  Does NOT allow updating sensitive fields like api_key_hash, workspace_id, etc.
  """
  def update_registered_agent(%RegisteredAgent{} = agent, attrs) do
    agent
    |> RegisteredAgent.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deactivates a registered agent by setting status to `:suspended`
  and recording `last_seen_at`.
  """
  def deactivate_registered_agent(%RegisteredAgent{} = agent) do
    now = DateTime.utc_now(:second)

    agent
    |> Ecto.Changeset.change(%{status: :suspended, last_seen_at: now})
    |> Repo.update()
  end

  @doc """
  Regenerates the API key for a registered agent.

  Returns `{:ok, agent, raw_api_key}` with the new plaintext key.
  The old key is immediately invalidated.
  """
  def regenerate_api_key(%RegisteredAgent{} = agent) do
    {raw_key, hash, prefix} = RegisteredAgent.generate_api_key()

    result =
      agent
      |> RegisteredAgent.api_key_changeset(%{api_key_hash: hash, api_key_prefix: prefix})
      |> Repo.update()

    case result do
      {:ok, agent} -> {:ok, agent, raw_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Deletes a registered agent. Returns `{:ok, agent}` or `{:error, reason}`.

  Prevents deletion if the agent has events within the last 24 hours.
  """
  def delete_registered_agent(%RegisteredAgent{} = agent) do
    since = DateTime.add(DateTime.utc_now(:second), -24, :hour)

    recent_count =
      from(e in AgentEvent,
        where: e.registered_agent_id == ^agent.id and e.inserted_at >= ^since,
        select: count(e.id)
      )
      |> Repo.one()

    if recent_count > 0 do
      {:error, "Cannot delete agent with #{recent_count} event(s) in the last 24 hours."}
    else
      Repo.delete(agent)
    end
  end

  @doc """
  Returns a changeset for tracking agent form changes.
  """
  def change_registered_agent(%RegisteredAgent{} = agent, attrs \\ %{}) do
    RegisteredAgent.changeset(agent, attrs)
  end

  @doc """
  Gets a registered agent by ID scoped to a workspace.
  Raises `Ecto.NoResultsError` if not found.
  """
  def get_registered_agent_for_workspace!(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    from(a in RegisteredAgent,
      where: a.id == ^id and a.workspace_id == ^workspace_id
    )
    |> Repo.one!()
  end

  @doc """
  Updates last_seen_at for a registered agent atomically.

  Uses `Repo.update_all` to avoid read-modify-write race conditions.
  Designed to be called from async contexts (e.g., Task.Supervisor)
  so it does not block API response paths.
  """
  def touch_agent_last_seen(agent_id) when is_binary(agent_id) do
    now = DateTime.utc_now(:second)

    from(a in RegisteredAgent, where: a.id == ^agent_id)
    |> Repo.update_all(set: [last_seen_at: now])

    :ok
  end

  @doc """
  Returns a list of `{name, id}` tuples for all agents in a workspace.
  Used for filter dropdowns in LiveViews. Lightweight: only selects id and name.
  """
  def list_agents_for_select(workspace_id) when is_binary(workspace_id) do
    from(a in RegisteredAgent,
      where: a.workspace_id == ^workspace_id,
      select: {a.name, a.id},
      order_by: [asc: a.name]
    )
    |> Repo.all()
  end

  # ---------------------------------------------------------------------------
  # Dashboard Stats (single query with conditional aggregates)
  # ---------------------------------------------------------------------------

  @doc """
  Returns dashboard statistics for a workspace using conditional aggregates.

  Executes TWO optimized queries (events + agents) instead of N+1:
  1. Event stats: total_events_24h, flagged_events, blocked_events via FILTER
  2. Agent stats: active_agents count

  Returns a map with integer values. All counts default to 0.
  """
  def get_dashboard_stats(workspace_id) when is_binary(workspace_id) do
    since = DateTime.add(DateTime.utc_now(:second), -24, :hour)

    event_stats =
      from(e in AgentEvent,
        where: e.workspace_id == ^workspace_id,
        select: %{
          total_events_24h: count(e.id) |> filter(e.inserted_at >= ^since),
          flagged_events: count(e.id) |> filter(e.status == :flagged and e.inserted_at >= ^since),
          blocked_events: count(e.id) |> filter(e.status == :blocked and e.inserted_at >= ^since)
        }
      )
      |> Repo.one()

    active_agents =
      from(a in RegisteredAgent,
        where: a.workspace_id == ^workspace_id and a.status == :active,
        select: count(a.id)
      )
      |> Repo.one()

    Map.put(event_stats, :active_agents, active_agents || 0)
  end

  # ---------------------------------------------------------------------------
  # AgentEvent
  # ---------------------------------------------------------------------------

  @doc """
  Lists agent events for a workspace with composable filters and pagination.

  All filters compose as a single query with AND conditions. Uses database-level
  WHERE for filters and LIMIT/OFFSET for pagination.

  Returns `{events, total_count}`.

  ## Options

    * `:registered_agent_id` - filter by agent UUID
    * `:event_type` - filter by event type atom
    * `:status` - filter by status atom
    * `:severity` - filter by severity atom
    * `:search` - search content by text (case-insensitive ILIKE, sanitized)
    * `:from` - start datetime (inclusive)
    * `:to` - end datetime (inclusive)
    * `:page` - page number (default 1)
    * `:page_size` - items per page (default 50, max 100)
  """
  def list_agent_events(workspace_id, opts \\ [])

  def list_agent_events(workspace_id, opts) when is_binary(workspace_id) do
    {_page, page_size, offset} = pagination_params(opts)

    base_query =
      from(e in AgentEvent,
        where: e.workspace_id == ^workspace_id,
        preload: [:registered_agent]
      )
      |> apply_event_filters(opts)

    total_count = Repo.aggregate(base_query, :count)

    events =
      base_query
      |> order_by([e], desc: e.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {events, total_count}
  end

  @doc """
  Gets a single agent event by ID with preloaded associations.

  Raises `Ecto.NoResultsError` if not found.
  """
  def get_agent_event!(id) when is_binary(id) do
    AgentEvent
    |> Repo.get!(id)
    |> Repo.preload(:registered_agent)
  end

  @doc """
  Gets an agent event scoped to a workspace. Returns nil if not found
  or if the event doesn't belong to the workspace.
  """
  def get_agent_event_for_workspace(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    AgentEvent
    |> where([e], e.id == ^id and e.workspace_id == ^workspace_id)
    |> Repo.one()
    |> case do
      nil -> nil
      event -> Repo.preload(event, :registered_agent)
    end
  end

  @doc """
  Creates an agent event and atomically increments the registered agent's
  event_count using `Repo.update_all(inc: ...)` to avoid read-modify-write races.

  `workspace_id`, `registered_agent_id`, and `source_ip` are set server-side.

  ## Options

    * `:source_ip` - client IP address (extracted from conn.remote_ip)
  """
  def create_agent_event(workspace_id, registered_agent_id, attrs, opts \\ [])

  def create_agent_event(workspace_id, registered_agent_id, attrs, opts)
      when is_binary(workspace_id) and is_binary(registered_agent_id) do
    source_ip = Keyword.get(opts, :source_ip)

    Repo.transaction(fn ->
      event_result =
        %AgentEvent{workspace_id: workspace_id, registered_agent_id: registered_agent_id}
        |> AgentEvent.changeset(attrs)
        |> maybe_set_source_ip(source_ip)
        |> Repo.insert()

      case event_result do
        {:ok, event} ->
          # Atomic increment - no read-modify-write race condition
          {1, _} =
            from(a in RegisteredAgent,
              where: a.id == ^registered_agent_id and a.workspace_id == ^workspace_id
            )
            |> Repo.update_all(
              inc: [event_count: 1],
              set: [last_seen_at: DateTime.utc_now(:second)]
            )

          event

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Updates an agent event's status with validation of allowed transitions.

  Only `pending` events can transition to `allowed`, `flagged`, or `blocked`.
  Terminal states cannot be changed.
  """
  def update_agent_event_status(%AgentEvent{} = event, new_status)
      when is_atom(new_status) do
    current_status = event.status
    allowed_transitions = Map.get(@valid_event_status_transitions, current_status, [])

    if new_status in allowed_transitions do
      now = DateTime.utc_now(:second)

      event
      |> AgentEvent.evaluation_changeset(%{
        status: new_status,
        evaluated_at: now
      })
      |> Repo.update()
    else
      {:error,
       event
       |> Ecto.Changeset.change()
       |> Ecto.Changeset.add_error(
         :status,
         "cannot transition from #{current_status} to #{new_status}"
       )}
    end
  end

  @doc """
  Updates an agent event with full evaluation results from the PolicyEngine.
  """
  def update_agent_event_evaluation(%AgentEvent{status: :pending} = event, attrs) do
    event
    |> AgentEvent.evaluation_changeset(attrs)
    |> Repo.update()
  end

  def update_agent_event_evaluation(%AgentEvent{status: status}, _attrs) do
    {:error, "cannot update evaluation for event with status #{status}"}
  end

  @doc """
  Evaluates a pending event against cached policy rules and updates its status.

  Flow: evaluate via PolicyEngine -> update event status -> create PolicyViolation
  records for flagged/blocked events.

  On PolicyEngine failure: event stays :pending, no crash.
  Returns `{:ok, updated_event}` on success or `{:ok, original_event}` on
  evaluation failure (event remains :pending).
  """
  def evaluate_event(%AgentEvent{status: :pending} = event, workspace_id)
      when is_binary(workspace_id) do
    {action, matched_rules, details} = PolicyEngine.evaluate(event, workspace_id)

    status = action_to_status(action)
    now = DateTime.utc_now(:second)

    evaluation_result = %{
      "action" => to_string(action),
      "matched_rules" => sanitize_matched_rules(matched_rules),
      "evaluated_count" => details.evaluated_count,
      "block_count" => details.block_count,
      "flag_count" => details.flag_count,
      "duration_us" => details.duration_us
    }

    flagged_reason = build_flagged_reason(action, matched_rules)

    case update_agent_event_evaluation(event, %{
           status: status,
           evaluation_result: evaluation_result,
           evaluated_at: now,
           flagged_reason: flagged_reason
         }) do
      {:ok, updated_event} ->
        violations =
          create_violations_for_matched_rules(
            workspace_id,
            updated_event,
            action,
            matched_rules
          )

        broadcast_event_created(updated_event, workspace_id)
        broadcast_violations_created(violations, workspace_id, action)
        maybe_trigger_deliberation(updated_event, workspace_id, action)

        {:ok, updated_event}

      {:error, _reason} ->
        {:ok, event}
    end
  catch
    _kind, _reason ->
      Logger.warning(
        "[Gateway] PolicyEngine evaluation failed for event #{event.id}, staying :pending"
      )

      {:ok, event}
  end

  def evaluate_event(%AgentEvent{} = event, _workspace_id), do: {:ok, event}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp pagination_params(opts) do
    page = opts |> Keyword.get(:page, 1) |> max(1)

    page_size =
      opts |> Keyword.get(:page_size, @default_page_size) |> min(@max_page_size) |> max(1)

    offset = (page - 1) * page_size

    {page, page_size, offset}
  end

  # Agent filters - compose via pattern matching on nil/value

  defp apply_agent_filters(query, opts) do
    query
    |> maybe_filter_agent_status(Keyword.get(opts, :status))
    |> maybe_filter_agent_type(Keyword.get(opts, :agent_type))
    |> maybe_filter_agent_search(Keyword.get(opts, :search))
  end

  defp maybe_filter_agent_status(query, nil), do: query

  defp maybe_filter_agent_status(query, status),
    do: where(query, [a], a.status == ^status)

  defp maybe_filter_agent_type(query, nil), do: query

  defp maybe_filter_agent_type(query, agent_type),
    do: where(query, [a], a.agent_type == ^agent_type)

  defp maybe_filter_agent_search(query, nil), do: query
  defp maybe_filter_agent_search(query, ""), do: query

  defp maybe_filter_agent_search(query, search) when is_binary(search) do
    sanitized = "%" <> String.replace(search, ["%", "_", "\\"], &"\\#{&1}") <> "%"

    where(query, [a], ilike(a.name, ^sanitized))
  end

  # Event filters - compose as AND conditions in a single query

  defp apply_event_filters(query, opts) do
    query
    |> maybe_filter_event_agent(Keyword.get(opts, :registered_agent_id))
    |> maybe_filter_event_type(Keyword.get(opts, :event_type))
    |> maybe_filter_event_status(Keyword.get(opts, :status))
    |> maybe_filter_event_severity(Keyword.get(opts, :severity))
    |> maybe_filter_event_search(Keyword.get(opts, :search))
    |> maybe_filter_event_from(Keyword.get(opts, :from))
    |> maybe_filter_event_to(Keyword.get(opts, :to))
  end

  defp maybe_filter_event_agent(query, nil), do: query

  defp maybe_filter_event_agent(query, agent_id),
    do: where(query, [e], e.registered_agent_id == ^agent_id)

  defp maybe_filter_event_type(query, nil), do: query

  defp maybe_filter_event_type(query, event_type),
    do: where(query, [e], e.event_type == ^event_type)

  defp maybe_filter_event_status(query, nil), do: query

  defp maybe_filter_event_status(query, status),
    do: where(query, [e], e.status == ^status)

  defp maybe_filter_event_severity(query, nil), do: query

  defp maybe_filter_event_severity(query, severity),
    do: where(query, [e], e.severity == ^severity)

  defp maybe_filter_event_search(query, nil), do: query
  defp maybe_filter_event_search(query, ""), do: query

  defp maybe_filter_event_search(query, search) when is_binary(search) do
    sanitized = "%" <> String.replace(search, ["%", "_", "\\"], &"\\#{&1}") <> "%"
    where(query, [e], ilike(e.content, ^sanitized))
  end

  defp maybe_filter_event_from(query, nil), do: query

  defp maybe_filter_event_from(query, %DateTime{} = from),
    do: where(query, [e], e.inserted_at >= ^from)

  defp maybe_filter_event_to(query, nil), do: query

  defp maybe_filter_event_to(query, %DateTime{} = to),
    do: where(query, [e], e.inserted_at <= ^to)

  defp maybe_set_source_ip(changeset, nil), do: changeset

  defp maybe_set_source_ip(changeset, source_ip) when is_binary(source_ip) do
    Ecto.Changeset.change(changeset, %{source_ip: source_ip})
  end

  # PolicyEngine evaluation helpers

  defp action_to_status(:allow), do: :allowed
  defp action_to_status(:flag), do: :flagged
  defp action_to_status(:block), do: :blocked

  defp sanitize_matched_rules(matched_rules) do
    Enum.map(matched_rules, fn rule ->
      %{
        "rule_id" => rule.rule_id,
        "rule_name" => rule.rule_name,
        "action" => to_string(rule.action),
        "rule_type" => to_string(rule.rule_type)
      }
    end)
  end

  defp build_flagged_reason(:allow, _matched_rules), do: nil

  defp build_flagged_reason(action, matched_rules) do
    rule_names = Enum.map(matched_rules, & &1.rule_name)

    "#{action}: matched #{length(matched_rules)} rule(s) - #{Enum.join(rule_names, ", ")}"
  end

  defp create_violations_for_matched_rules(_workspace_id, _event, :allow, _matched_rules), do: []

  defp create_violations_for_matched_rules(workspace_id, event, action, matched_rules) do
    action_taken = action_to_violation_action(action)
    severity = action_to_violation_severity(action)

    Enum.reduce(matched_rules, [], fn rule_match, acc ->
      try do
        case Policies.create_policy_violation(%{
               workspace_id: workspace_id,
               agent_event_id: event.id,
               policy_rule_id: rule_match.rule_id,
               action_taken: action_taken,
               severity: severity,
               details: %{
                 "rule_name" => rule_match.rule_name,
                 "rule_type" => to_string(rule_match.rule_type)
               }
             }) do
          {:ok, violation} -> [violation | acc]
          {:error, _changeset} -> acc
        end
      catch
        _kind, _reason ->
          Logger.warning(
            "[Gateway] Failed to create violation for event #{event.id}, rule #{rule_match.rule_id}"
          )

          acc
      end
    end)
  end

  defp action_to_violation_action(:flag), do: :flagged
  defp action_to_violation_action(:block), do: :blocked

  defp action_to_violation_severity(:block), do: :high
  defp action_to_violation_severity(:flag), do: :medium

  # PubSub broadcasts for real-time dashboard updates

  defp broadcast_event_created(event, workspace_id) do
    event_with_agent = Repo.preload(event, :registered_agent)

    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "events:#{workspace_id}",
      {:event_created, event_with_agent}
    )
  rescue
    _ -> :ok
  end

  defp broadcast_violations_created(_violations, _workspace_id, :allow), do: :ok

  defp broadcast_violations_created(violations, workspace_id, _action) do
    # Batch preload to avoid N+1 (one query for all violations, not one per violation)
    violations_with_preloads = Repo.preload(violations, [:agent_event, :policy_rule])

    Enum.each(violations_with_preloads, fn violation ->
      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "violations:#{workspace_id}",
        {:violation_created, violation}
      )
    end)
  rescue
    _ -> :ok
  end

  # Deliberation trigger - only for flagged events, async via Task.Supervisor

  defp maybe_trigger_deliberation(_event, _workspace_id, :allow), do: :ok
  defp maybe_trigger_deliberation(_event, _workspace_id, :block), do: :ok

  defp maybe_trigger_deliberation(event, workspace_id, :flag) do
    event_id = event.id

    Task.Supervisor.start_child(
      Swarmshield.TaskSupervisor,
      fn ->
        try do
          do_trigger_deliberation(event_id, workspace_id)
        catch
          _kind, _reason -> :ok
        end
      end
    )

    :ok
  end

  defp do_trigger_deliberation(event_id, workspace_id) do
    case Workflows.get_enabled_workflow_for_trigger(workspace_id, :flagged) do
      nil ->
        :ok

      workflow ->
        event = get_agent_event!(event_id)

        case DeliberationSession.start_session(event, workflow) do
          {:ok, pid} ->
            Logger.info(
              "[Gateway] Deliberation session started for event #{event_id}, pid=#{inspect(pid)}"
            )

          {:error, reason} ->
            Logger.warning(
              "[Gateway] Failed to start deliberation for event #{event_id}: #{inspect(reason)}"
            )
        end

        Phoenix.PubSub.broadcast(
          Swarmshield.PubSub,
          "deliberations:#{workspace_id}",
          {:trigger_deliberation, event_id, workflow}
        )

        Accounts.create_audit_entry(%{
          action: "deliberation.auto_triggered",
          resource_type: "agent_event",
          resource_id: event_id,
          workspace_id: workspace_id,
          metadata: %{
            "workflow_id" => workflow.id,
            "workflow_name" => workflow.name,
            "trigger" => "flagged_event"
          }
        })
    end
  end
end
