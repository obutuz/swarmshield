defmodule Swarmshield.GhostProtocol do
  @moduledoc """
  The GhostProtocol context manages GhostProtocolConfig CRUD and
  active ephemeral session queries.

  All operations are workspace-scoped. PubSub broadcasts on config
  changes for real-time LiveView updates.
  """

  import Ecto.Query, warn: false
  alias Swarmshield.Repo

  alias Swarmshield.Accounts
  alias Swarmshield.Deliberation.{AnalysisSession, Workflow}
  alias Swarmshield.GhostProtocol.Config

  @default_page_size 50
  @max_page_size 100

  # ---------------------------------------------------------------------------
  # Config CRUD
  # ---------------------------------------------------------------------------

  def list_configs(workspace_id, opts \\ [])

  def list_configs(workspace_id, opts) when is_binary(workspace_id) do
    {_page, page_size, offset} = pagination_params(opts)

    base_query = from(c in Config, where: c.workspace_id == ^workspace_id)

    total_count = Repo.aggregate(base_query, :count)

    configs =
      base_query
      |> preload(:workflows)
      |> order_by([c], desc: c.inserted_at)
      |> limit(^page_size)
      |> offset(^offset)
      |> Repo.all()

    {configs, total_count}
  end

  def list_enabled_configs_for_select(workspace_id) when is_binary(workspace_id) do
    from(c in Config,
      where: c.workspace_id == ^workspace_id and c.enabled == true,
      order_by: [asc: c.name],
      select: {c.id, c.name}
    )
    |> Repo.all()
  end

  def get_config!(id) when is_binary(id) do
    Config
    |> Repo.get!(id)
    |> Repo.preload(:workflows)
  end

  def get_config_for_workspace!(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    Config
    |> where([c], c.id == ^id and c.workspace_id == ^workspace_id)
    |> Repo.one!()
    |> Repo.preload(:workflows)
  end

  def create_config(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    result =
      %Config{workspace_id: workspace_id}
      |> Config.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, config} ->
        broadcast_config_change(config, :config_created)
        audit_config_action(config, "ghost_protocol.config_created", workspace_id)
        {:ok, config}

      error ->
        error
    end
  end

  def update_config(%Config{} = config, attrs) when is_map(attrs) do
    result =
      config
      |> Config.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated} ->
        broadcast_config_change(updated, :config_updated)
        audit_config_action(updated, "ghost_protocol.config_updated", updated.workspace_id)
        {:ok, updated}

      error ->
        error
    end
  end

  def delete_config(%Config{} = config) do
    has_workflows? =
      from(w in Workflow,
        where: w.ghost_protocol_config_id == ^config.id,
        select: true,
        limit: 1
      )
      |> Repo.exists?()

    case has_workflows? do
      true ->
        {:error, :has_linked_workflows}

      false ->
        result = Repo.delete(config)

        case result do
          {:ok, deleted} ->
            broadcast_config_change(deleted, :config_deleted)
            audit_config_action(deleted, "ghost_protocol.config_deleted", deleted.workspace_id)
            {:ok, deleted}

          error ->
            error
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Ephemeral Session Queries
  # ---------------------------------------------------------------------------

  def list_active_ephemeral_sessions(workspace_id) when is_binary(workspace_id) do
    active_statuses = [:pending, :analyzing, :deliberating, :voting]

    from(s in AnalysisSession,
      join: w in Workflow,
      on: w.id == s.workflow_id,
      where:
        s.workspace_id == ^workspace_id and
          s.status in ^active_statuses and
          not is_nil(w.ghost_protocol_config_id),
      preload: [:verdict, workflow: {w, :ghost_protocol_config}],
      order_by: [desc: s.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Lists completed ephemeral sessions (wipe history) for a workspace.

  Returns sessions that have completed and were linked to a ghost_protocol_config,
  ordered by most recently completed. Preloads workflow with ghost_protocol_config.
  """
  def list_completed_ephemeral_sessions(workspace_id, opts \\ [])

  def list_completed_ephemeral_sessions(workspace_id, opts) when is_binary(workspace_id) do
    page_size = Keyword.get(opts, :page_size, 20) |> min(100) |> max(1)

    from(s in AnalysisSession,
      join: w in Workflow,
      on: w.id == s.workflow_id,
      where:
        s.workspace_id == ^workspace_id and
          s.status in [:completed, :failed, :timed_out] and
          not is_nil(w.ghost_protocol_config_id),
      preload: [workflow: {w, :ghost_protocol_config}],
      order_by: [desc: s.completed_at, desc: s.inserted_at],
      limit: ^page_size
    )
    |> Repo.all()
  end

  def get_session_with_ghost_config(session_id) when is_binary(session_id) do
    from(s in AnalysisSession,
      where: s.id == ^session_id,
      preload: [workflow: :ghost_protocol_config]
    )
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  def subscribe_to_workspace(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(Swarmshield.PubSub, "ghost_protocol:#{workspace_id}")
  end

  def subscribe_to_session(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(Swarmshield.PubSub, "ghost_protocol:session:#{session_id}")
  end

  defp broadcast_config_change(%Config{} = config, event) do
    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "ghost_protocol:#{config.workspace_id}",
      {event, config.id}
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------
  # Dashboard Stats
  # ---------------------------------------------------------------------------

  @doc """
  Returns GhostProtocol dashboard statistics for a workspace.

  Uses JOINs through workflow -> ghost_protocol_config to identify
  ephemeral sessions. Single query with conditional aggregates.

  Returns a map with:
  - active_ephemeral_sessions: sessions in active states linked to a ghost config
  - total_sessions_wiped: completed ephemeral sessions
  - active_configs: enabled ghost protocol configs
  """
  def get_dashboard_stats(workspace_id) when is_binary(workspace_id) do
    active_statuses = [:pending, :analyzing, :deliberating, :voting]

    session_stats =
      from(s in AnalysisSession,
        join: w in Workflow,
        on: w.id == s.workflow_id,
        where: s.workspace_id == ^workspace_id and not is_nil(w.ghost_protocol_config_id),
        select: %{
          active_ephemeral_sessions: count(s.id) |> filter(s.status in ^active_statuses),
          total_sessions_wiped: count(s.id) |> filter(s.status == :completed)
        }
      )
      |> Repo.one() || %{active_ephemeral_sessions: 0, total_sessions_wiped: 0}

    active_configs =
      from(c in Config,
        where: c.workspace_id == ^workspace_id and c.enabled == true,
        select: count(c.id)
      )
      |> Repo.one() || 0

    Map.put(session_stats, :active_configs, active_configs)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp audit_config_action(%Config{} = config, action, workspace_id) do
    config_id = config.id
    config_name = config.name

    Task.Supervisor.start_child(Swarmshield.TaskSupervisor, fn ->
      try do
        Accounts.create_audit_entry(%{
          action: action,
          resource_type: "ghost_protocol_config",
          resource_id: config_id,
          workspace_id: workspace_id,
          metadata: %{"config_name" => config_name}
        })
      catch
        _kind, _reason -> :ok
      end
    end)
  end

  defp pagination_params(opts) do
    page = opts |> Keyword.get(:page, 1) |> max(1)

    page_size =
      opts |> Keyword.get(:page_size, @default_page_size) |> min(@max_page_size) |> max(1)

    offset = (page - 1) * page_size
    {page, page_size, offset}
  end
end
