defmodule Swarmshield.Policies.PolicyCache do
  @moduledoc """
  ETS-backed cache for sub-millisecond policy rule and detection rule lookups.

  At 20M users, every API event is evaluated against policy rules. Hitting the
  database for each evaluation would be catastrophic. This GenServer owns two
  ETS tables and manages cache loading + PubSub-driven invalidation.

  Architecture:
  - GenServer owns ETS tables (for lifecycle management)
  - All reads go directly to ETS (no GenServer bottleneck)
  - GenServer handles PubSub-driven cache refresh messages
  - Per-workspace refresh (never global flush)
  - Debounced refresh to prevent thundering herd on bulk rule updates

  ETS Tables:
  - `:policy_rules_cache` - {workspace_id, [%PolicyRule{}, ...]}
  - `:detection_rules_cache` - {workspace_id, [%DetectionRule{}, ...]}
  """

  use GenServer

  alias Swarmshield.Policies.Rules.RateLimit

  require Logger

  @policy_rules_table :policy_rules_cache
  @detection_rules_table :detection_rules_cache

  # Debounce interval to prevent thundering herd on bulk updates
  @debounce_ms 500

  # ---------------------------------------------------------------------------
  # Client API - Direct ETS reads (no GenServer bottleneck)
  # ---------------------------------------------------------------------------

  @doc """
  Returns enabled policy rules for a workspace from ETS cache.

  On cache miss, returns empty list (cache will be populated on next refresh).
  On ETS table destroyed, returns empty list (not crash).
  """
  def get_rules(workspace_id) when is_binary(workspace_id) do
    case :ets.lookup(@policy_rules_table, workspace_id) do
      [{^workspace_id, rules}] -> rules
      [] -> []
    end
  rescue
    ArgumentError ->
      Logger.warning("[PolicyCache] policy_rules ETS table not available")
      []
  end

  @doc """
  Returns enabled detection rules for a workspace from ETS cache.

  On cache miss, returns empty list.
  On ETS table destroyed, returns empty list (not crash).
  """
  def get_detection_rules(workspace_id) when is_binary(workspace_id) do
    case :ets.lookup(@detection_rules_table, workspace_id) do
      [{^workspace_id, rules}] -> rules
      [] -> []
    end
  rescue
    ArgumentError ->
      Logger.warning("[PolicyCache] detection_rules ETS table not available")
      []
  end

  @doc """
  Triggers a refresh of cached rules for a specific workspace.

  Goes through the GenServer for serialized write access with debouncing.
  """
  def refresh(workspace_id) when is_binary(workspace_id) do
    GenServer.cast(__MODULE__, {:refresh_workspace, workspace_id})
  end

  @doc """
  Triggers a full reload of all cached rules from the database.

  Goes through the GenServer for serialized write access.
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
    state = %{
      pending_refreshes: %{},
      debounce_timers: %{}
    }

    {:ok, state, {:continue, :load_cache}}
  end

  @impl true
  def handle_continue(:load_cache, state) do
    try do
      :ets.new(@policy_rules_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])

      :ets.new(@detection_rules_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true
      ])

      # Initialize rate limit counters table (used by RateLimit rule evaluator)
      RateLimit.init_table()

      load_all_rules()

      # Subscribe to wildcard-like pattern - we subscribe to specific workspace
      # topics as we discover workspaces, plus a global topic for initial load
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "policy_cache:refresh")

      Logger.info("[PolicyCache] ETS cache initialized with policy and detection rules")
    rescue
      e ->
        Logger.warning(
          "[PolicyCache] Initial load failed: #{Exception.message(e)}. " <>
            "Cache will be empty until next refresh."
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:refresh_workspace, workspace_id}, state) do
    state = schedule_debounced_refresh(state, workspace_id)
    {:noreply, state}
  end

  def handle_cast(:refresh_all, state) do
    try do
      load_all_rules()
      Logger.info("[PolicyCache] Full cache refresh completed")
    rescue
      e ->
        Logger.warning("[PolicyCache] Full refresh failed: #{Exception.message(e)}")
    end

    {:noreply, state}
  end

  def handle_cast({:subscribe_workspace, workspace_id}, state) do
    Phoenix.PubSub.subscribe(Swarmshield.PubSub, "policy_rules:#{workspace_id}")
    Phoenix.PubSub.subscribe(Swarmshield.PubSub, "detection_rules:#{workspace_id}")
    {:noreply, state}
  end

  @impl true
  def handle_info({:debounced_refresh, workspace_id}, state) do
    try do
      load_workspace_rules(workspace_id)
    rescue
      e ->
        Logger.warning(
          "[PolicyCache] Workspace #{workspace_id} refresh failed: #{Exception.message(e)}"
        )
    end

    # Clean up debounce state
    state = %{
      state
      | pending_refreshes: Map.delete(state.pending_refreshes, workspace_id),
        debounce_timers: Map.delete(state.debounce_timers, workspace_id)
    }

    {:noreply, state}
  end

  # PubSub handler: policy rules changed for a specific workspace
  def handle_info({:policy_rules_changed, _action, _rule_id}, state) do
    # This message doesn't include workspace_id directly because PubSub topics
    # are already workspace-scoped. The GenServer subscribes per-workspace.
    {:noreply, state}
  end

  # Direct workspace refresh from PubSub
  def handle_info({:refresh_workspace, workspace_id}, state) do
    state = schedule_debounced_refresh(state, workspace_id)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # PubSub subscription for workspace-specific topics
  # ---------------------------------------------------------------------------

  @doc """
  Subscribes the PolicyCache GenServer to PubSub topics for a specific workspace.

  Called when a workspace's rules are first loaded or when the cache needs to
  track a new workspace. This allows per-workspace targeted cache invalidation.
  """
  def subscribe_to_workspace(workspace_id) when is_binary(workspace_id) do
    GenServer.cast(__MODULE__, {:subscribe_workspace, workspace_id})
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_all_rules do
    workspace_ids = list_workspace_ids()

    Enum.each(workspace_ids, fn workspace_id ->
      load_workspace_rules(workspace_id)

      # Subscribe to PubSub for each workspace
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "policy_rules:#{workspace_id}")
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "detection_rules:#{workspace_id}")
    end)
  end

  defp load_workspace_rules(workspace_id) do
    policy_rules = Swarmshield.Policies.list_enabled_policy_rules(workspace_id)
    detection_rules = Swarmshield.Policies.list_enabled_detection_rules(workspace_id)

    :ets.insert(@policy_rules_table, {workspace_id, policy_rules})
    :ets.insert(@detection_rules_table, {workspace_id, detection_rules})
  end

  defp list_workspace_ids do
    import Ecto.Query

    Swarmshield.Repo.all(from(w in Swarmshield.Accounts.Workspace, select: w.id))
  rescue
    _ -> []
  end

  defp schedule_debounced_refresh(state, workspace_id) do
    # Cancel existing timer for this workspace if any
    case Map.get(state.debounce_timers, workspace_id) do
      nil -> :ok
      timer_ref -> Process.cancel_timer(timer_ref)
    end

    # Schedule new debounced refresh
    timer_ref = Process.send_after(self(), {:debounced_refresh, workspace_id}, @debounce_ms)

    %{
      state
      | pending_refreshes: Map.put(state.pending_refreshes, workspace_id, true),
        debounce_timers: Map.put(state.debounce_timers, workspace_id, timer_ref)
    }
  end
end
