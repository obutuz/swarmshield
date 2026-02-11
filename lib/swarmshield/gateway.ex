defmodule Swarmshield.Gateway do
  @moduledoc """
  The Gateway context manages RegisteredAgent and AgentEvent CRUD operations.

  This is the ingestion layer for SwarmShield. External AI agents authenticate
  via API keys, and their actions/outputs are captured as AgentEvents. All
  operations are workspace-scoped for multi-tenant isolation.
  """

  import Ecto.Query, warn: false
  alias Swarmshield.Repo

  alias Swarmshield.Gateway.{AgentEvent, RegisteredAgent}

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
  Creates an agent event and atomically increments the registered agent's
  event_count using `Repo.update_all(inc: ...)` to avoid read-modify-write races.

  `workspace_id` and `registered_agent_id` are set server-side.
  """
  def create_agent_event(workspace_id, registered_agent_id, attrs)
      when is_binary(workspace_id) and is_binary(registered_agent_id) do
    Repo.transaction(fn ->
      event_result =
        %AgentEvent{workspace_id: workspace_id, registered_agent_id: registered_agent_id}
        |> AgentEvent.changeset(attrs)
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

  defp maybe_filter_event_from(query, nil), do: query

  defp maybe_filter_event_from(query, %DateTime{} = from),
    do: where(query, [e], e.inserted_at >= ^from)

  defp maybe_filter_event_to(query, nil), do: query

  defp maybe_filter_event_to(query, %DateTime{} = to),
    do: where(query, [e], e.inserted_at <= ^to)
end
