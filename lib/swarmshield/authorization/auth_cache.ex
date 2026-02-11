defmodule Swarmshield.Authorization.AuthCache do
  @moduledoc """
  ETS-backed cache for user+workspace permission lookups.

  At 20M users, has_permission?/3 is called on every handle_event. Hitting the
  database each time would be catastrophic. This GenServer owns an ETS table
  for fast reads while managing cache invalidation via PubSub.

  Architecture:
  - GenServer owns the ETS table (for lifecycle management)
  - All reads go directly to ETS (no GenServer bottleneck)
  - GenServer handles PubSub-driven invalidation messages
  - TTL-based expiry checked on read, refresh if stale
  """

  use GenServer

  require Logger

  @table :auth_permissions_cache
  @default_ttl_seconds 300
  @pubsub_topic "auth:permissions_changed"

  # Client API - Direct ETS reads (no GenServer bottleneck)

  @doc """
  Looks up cached permissions for a user+workspace pair.
  Returns `{:ok, permissions}` or `:miss` if not cached or expired.

  Reads directly from ETS - does NOT go through GenServer.
  """
  def get_permissions(user_id, workspace_id) do
    case :ets.lookup(@table, {user_id, workspace_id}) do
      [{_key, permissions, inserted_at}] ->
        if expired?(inserted_at) do
          :ets.delete(@table, {user_id, workspace_id})
          :miss
        else
          {:ok, permissions}
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError ->
      Logger.warning("[AuthCache] ETS table not available, returning cache miss")
      :miss
  end

  @doc """
  Stores permissions in the ETS cache.
  Writes directly to ETS (public table, no GenServer needed).
  """
  def put_permissions(user_id, workspace_id, permissions) do
    now = System.monotonic_time(:second)
    :ets.insert(@table, {{user_id, workspace_id}, permissions, now})
    :ok
  rescue
    ArgumentError ->
      Logger.warning("[AuthCache] ETS table not available, cannot cache permissions")
      :ok
  end

  @doc """
  Invalidates cached permissions for a specific user+workspace pair.
  Also broadcasts to PubSub for cross-node invalidation.
  """
  def invalidate(user_id, workspace_id) do
    :ets.delete(@table, {user_id, workspace_id})

    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      @pubsub_topic,
      {:invalidate_user, user_id, workspace_id}
    )

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Invalidates ALL cached permissions for a workspace.
  Used when role permissions change (affects all users in workspace).
  Also broadcasts to PubSub for cross-node invalidation.
  """
  def invalidate_workspace(workspace_id) do
    match_spec = [{{{:_, workspace_id}, :_, :_}, [], [true]}]
    :ets.select_delete(@table, match_spec)

    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      @pubsub_topic,
      {:invalidate_workspace, workspace_id}
    )

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Returns the PubSub topic for permission changes.
  """
  def pubsub_topic, do: @pubsub_topic

  # GenServer callbacks

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    {:ok, %{ttl: ttl}, {:continue, :init_cache}}
  end

  @impl true
  def handle_continue(:init_cache, state) do
    try do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, @pubsub_topic)
      Logger.info("[AuthCache] ETS cache initialized, subscribed to #{@pubsub_topic}")
    rescue
      e ->
        Logger.warning(
          "[AuthCache] Initialization failed: #{Exception.message(e)}. Will retry on next restart."
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:invalidate_user, user_id, workspace_id}, state) do
    try do
      :ets.delete(@table, {user_id, workspace_id})
    rescue
      ArgumentError -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:invalidate_workspace, workspace_id}, state) do
    try do
      match_spec = [{{{:_, workspace_id}, :_, :_}, [], [true]}]
      :ets.select_delete(@table, match_spec)
    rescue
      ArgumentError -> :ok
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private helpers

  defp expired?(inserted_at) do
    now = System.monotonic_time(:second)
    ttl = Application.get_env(:swarmshield, :auth_cache_ttl_seconds, @default_ttl_seconds)
    now - inserted_at > ttl
  end
end
