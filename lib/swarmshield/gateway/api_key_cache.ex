defmodule Swarmshield.Gateway.ApiKeyCache do
  @moduledoc """
  ETS-cached API key -> RegisteredAgent lookup for sub-millisecond API
  authentication.

  At 20M users, every API request hitting the database for key validation
  is catastrophic. This GenServer owns an ETS table mapping SHA256 key hash
  to agent metadata. PubSub-driven invalidation on status changes and key
  regeneration.

  Architecture:
  - GenServer owns ETS table (for lifecycle management)
  - All reads go directly to ETS (no GenServer bottleneck)
  - Cache miss triggers write-through from database
  - Negative caching: invalid key hashes cached as :not_found with 60s TTL
  - PubSub-driven invalidation for status changes and key rotation
  """

  use GenServer

  require Logger

  alias Swarmshield.Gateway
  alias Swarmshield.Gateway.RegisteredAgent

  @table :api_key_cache
  @negative_cache_ttl_seconds 60

  # ---------------------------------------------------------------------------
  # Client API - Direct ETS reads (no GenServer bottleneck)
  # ---------------------------------------------------------------------------

  @doc """
  Looks up a registered agent by API key hash from ETS cache.

  On cache hit, returns `{:ok, agent_info}` or `{:error, :suspended}`.
  On cache miss, queries database, caches the result, returns it.
  Invalid keys are negatively cached for 60s to prevent brute-force
  amplification on the database.

  Returns:
  - `{:ok, %{agent_id: id, workspace_id: id, status: atom, agent_name: string}}`
  - `{:error, :suspended}` if agent is suspended
  - `{:error, :not_found}` if key doesn't match any agent
  """
  def get_agent_by_key_hash(key_hash) when is_binary(key_hash) do
    case ets_lookup(key_hash) do
      {:hit, entry} -> process_cache_entry(entry)
      {:negative_hit, _} -> {:error, :not_found}
      :miss -> lookup_and_cache(key_hash)
    end
  end

  def get_agent_by_key_hash(_), do: {:error, :not_found}

  @doc """
  Invalidates the cache entry for a specific agent by agent_id.

  Scans the ETS table to find entries matching the agent_id and removes them.
  """
  def invalidate_agent(agent_id) when is_binary(agent_id) do
    try do
      # Match entries where agent_id matches (value position 2 in the tuple)
      match_spec = [{{:_, %{agent_id: agent_id}, :_}, [], [true]}]
      :ets.select_delete(@table, match_spec)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc """
  Invalidates a specific key hash entry from the cache.
  """
  def invalidate_key(key_hash) when is_binary(key_hash) do
    try do
      :ets.delete(@table, key_hash)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  @doc """
  Reloads all active agents into the cache from the database.
  Goes through GenServer for serialized write access.
  """
  def refresh_all do
    GenServer.cast(__MODULE__, :refresh_all)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :load_cache}}
  end

  @impl true
  def handle_continue(:load_cache, state) do
    try do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

      load_all_active_agents()

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "agents:status_changed")
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "agents:key_regenerated")
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "agents:deleted")

      Logger.info("[ApiKeyCache] ETS cache initialized with active agents")
    rescue
      e ->
        Logger.warning(
          "[ApiKeyCache] Initial load failed: #{Exception.message(e)}. " <>
            "Cache will populate on demand."
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:refresh_all, state) do
    try do
      load_all_active_agents()
      Logger.info("[ApiKeyCache] Full cache refresh completed")
    rescue
      e ->
        Logger.warning("[ApiKeyCache] Full refresh failed: #{Exception.message(e)}")
    end

    {:noreply, state}
  end

  @impl true
  # Agent status changed (suspended, reactivated, etc.)
  def handle_info({:agent_status_changed, agent_id}, state) do
    invalidate_agent(agent_id)
    {:noreply, state}
  end

  # API key regenerated - invalidate old hash
  def handle_info({:agent_key_regenerated, agent_id, old_key_hash}, state) do
    invalidate_key(old_key_hash)
    invalidate_agent(agent_id)
    {:noreply, state}
  end

  # Agent deleted
  def handle_info({:agent_deleted, agent_id}, state) do
    invalidate_agent(agent_id)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp ets_lookup(key_hash) do
    case :ets.lookup(@table, key_hash) do
      [{^key_hash, :not_found, inserted_at}] ->
        if negative_cache_expired?(inserted_at) do
          :ets.delete(@table, key_hash)
          :miss
        else
          {:negative_hit, :not_found}
        end

      [{^key_hash, agent_info, _inserted_at}] ->
        {:hit, agent_info}

      [] ->
        :miss
    end
  rescue
    ArgumentError ->
      Logger.warning("[ApiKeyCache] ETS table not available")
      :miss
  end

  defp process_cache_entry(%{status: :suspended}) do
    {:error, :suspended}
  end

  defp process_cache_entry(agent_info) do
    {:ok, agent_info}
  end

  defp lookup_and_cache(key_hash) do
    case Gateway.get_registered_agent_by_api_key(key_hash) do
      %RegisteredAgent{} = agent ->
        agent_info = build_agent_info(agent)
        cache_put(key_hash, agent_info)
        process_cache_entry(agent_info)

      nil ->
        # Negative cache to prevent repeated DB lookups for invalid keys
        cache_put_negative(key_hash)
        {:error, :not_found}
    end
  rescue
    e ->
      Logger.warning("[ApiKeyCache] DB lookup failed: #{Exception.message(e)}")
      {:error, :not_found}
  end

  defp build_agent_info(%RegisteredAgent{} = agent) do
    %{
      agent_id: agent.id,
      workspace_id: agent.workspace_id,
      status: agent.status,
      agent_name: agent.name
    }
  end

  defp cache_put(key_hash, agent_info) do
    now = System.monotonic_time(:second)
    :ets.insert(@table, {key_hash, agent_info, now})
  rescue
    ArgumentError -> :ok
  end

  defp cache_put_negative(key_hash) do
    now = System.monotonic_time(:second)
    :ets.insert(@table, {key_hash, :not_found, now})
  rescue
    ArgumentError -> :ok
  end

  defp negative_cache_expired?(inserted_at) do
    now = System.monotonic_time(:second)
    now - inserted_at > @negative_cache_ttl_seconds
  end

  defp load_all_active_agents do
    import Ecto.Query

    agents =
      Swarmshield.Repo.all(
        from(a in RegisteredAgent,
          where: a.status == :active,
          select: %{
            id: a.id,
            name: a.name,
            workspace_id: a.workspace_id,
            status: a.status,
            api_key_hash: a.api_key_hash
          }
        )
      )

    now = System.monotonic_time(:second)

    Enum.each(agents, fn agent ->
      agent_info = %{
        agent_id: agent.id,
        workspace_id: agent.workspace_id,
        status: agent.status,
        agent_name: agent.name
      }

      :ets.insert(@table, {agent.api_key_hash, agent_info, now})
    end)

    Logger.info("[ApiKeyCache] Loaded #{length(agents)} active agents into cache")
  end
end
