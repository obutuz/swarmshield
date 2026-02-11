defmodule Swarmshield.LLM.Budget do
  @moduledoc """
  GenServer tracking per-workspace API spending via ETS.

  Uses atomic ETS update_counter for concurrent safety.
  Budget limits are database-driven from workspace.settings["llm_budget_limit_cents"].
  """

  use GenServer

  require Logger

  alias Swarmshield.Repo

  @table :llm_budget
  @budget_cache :llm_budget_limits
  @default_budget_limit_cents 50_000
  @budget_cache_ttl_ms :timer.minutes(5)

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def track_usage(workspace_id, tokens, cost_cents, opts \\ [])

  def track_usage(workspace_id, tokens, cost_cents, opts)
      when is_binary(workspace_id) and is_integer(tokens) and tokens >= 0 and
             is_integer(cost_cents) and cost_cents >= 0 do
    table = Keyword.get(opts, :table, @table)

    try do
      :ets.update_counter(
        table,
        workspace_id,
        [{2, tokens}, {3, cost_cents}],
        {workspace_id, 0, 0, DateTime.utc_now(:second)}
      )

      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  @spec check_budget(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :budget_exceeded}
  def check_budget(workspace_id, opts \\ []) when is_binary(workspace_id) do
    table = Keyword.get(opts, :table, @table)
    usage = get_usage(workspace_id, table: table)
    limit_cents = get_budget_limit(workspace_id, opts)

    if usage.total_cost_cents >= limit_cents do
      {:error, :budget_exceeded}
    else
      {:ok, limit_cents - usage.total_cost_cents}
    end
  end

  @doc """
  Atomically reserves estimated cost in the budget BEFORE making an LLM call.

  Uses ETS update_counter to atomically increment cost, then checks if the
  new total exceeds the limit. If exceeded, rolls back the reservation.

  This prevents the TOCTOU race where concurrent sessions all pass check_budget
  before any of them track usage.

  Returns `{:ok, remaining}` or `{:error, :budget_exceeded}`.
  """
  @spec reserve_budget(String.t(), non_neg_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :budget_exceeded}
  def reserve_budget(workspace_id, estimated_cost_cents, opts \\ [])

  def reserve_budget(workspace_id, estimated_cost_cents, opts)
      when is_binary(workspace_id) and is_integer(estimated_cost_cents) and
             estimated_cost_cents > 0 do
    table = Keyword.get(opts, :table, @table)
    limit_cents = get_budget_limit(workspace_id, opts)

    try do
      # Atomically increment cost - single ETS operation, no TOCTOU race
      [new_cost] =
        :ets.update_counter(
          table,
          workspace_id,
          [{3, estimated_cost_cents}],
          {workspace_id, 0, 0, DateTime.utc_now(:second)}
        )

      if new_cost > limit_cents do
        # Rollback reservation atomically
        :ets.update_counter(table, workspace_id, [{3, -estimated_cost_cents}])
        {:error, :budget_exceeded}
      else
        {:ok, limit_cents - new_cost}
      end
    rescue
      ArgumentError -> {:error, :budget_exceeded}
    end
  end

  def reserve_budget(workspace_id, 0, _opts) when is_binary(workspace_id), do: {:ok, 0}

  @doc """
  Adjusts a previous reservation to match actual cost.

  After the LLM call completes, call this to correct the reservation:
  - If actual < estimated: releases the difference
  - If actual > estimated: adds the overage
  - Also tracks actual token count
  """
  @spec settle_reservation(
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) ::
          :ok
  def settle_reservation(workspace_id, estimated_cents, actual_cents, actual_tokens, opts \\ [])

  def settle_reservation(workspace_id, estimated_cents, actual_cents, actual_tokens, opts)
      when is_binary(workspace_id) do
    table = Keyword.get(opts, :table, @table)
    diff = actual_cents - estimated_cents

    try do
      :ets.update_counter(
        table,
        workspace_id,
        [{2, actual_tokens}, {3, diff}],
        {workspace_id, 0, 0, DateTime.utc_now(:second)}
      )

      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  @doc """
  Releases a full reservation when an LLM call fails (no cost incurred).
  """
  @spec release_reservation(String.t(), non_neg_integer(), keyword()) :: :ok
  def release_reservation(workspace_id, estimated_cost_cents, opts \\ [])

  def release_reservation(workspace_id, estimated_cost_cents, opts)
      when is_binary(workspace_id) and is_integer(estimated_cost_cents) do
    table = Keyword.get(opts, :table, @table)

    try do
      :ets.update_counter(
        table,
        workspace_id,
        [{3, -estimated_cost_cents}],
        {workspace_id, 0, 0, DateTime.utc_now(:second)}
      )

      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  def get_usage(workspace_id, opts \\ []) when is_binary(workspace_id) do
    table = Keyword.get(opts, :table, @table)

    try do
      case :ets.lookup(table, workspace_id) do
        [{^workspace_id, tokens, cost, period_start}] ->
          %{total_tokens: tokens, total_cost_cents: cost, period_start: period_start}

        [] ->
          %{total_tokens: 0, total_cost_cents: 0, period_start: nil}
      end
    rescue
      ArgumentError ->
        %{total_tokens: 0, total_cost_cents: 0, period_start: nil}
    end
  end

  def reset_usage(workspace_id, opts \\ []) when is_binary(workspace_id) do
    table = Keyword.get(opts, :table, @table)

    try do
      :ets.insert(table, {workspace_id, 0, 0, DateTime.utc_now(:second)})
      :ok
    rescue
      ArgumentError -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, @table)
    cache_name = Keyword.get(opts, :budget_cache, @budget_cache)

    table =
      case :ets.whereis(table_name) do
        :undefined ->
          :ets.new(table_name, [:named_table, :public, :set, read_concurrency: true])

        _ref ->
          table_name
      end

    cache =
      case :ets.whereis(cache_name) do
        :undefined ->
          :ets.new(cache_name, [:named_table, :public, :set, read_concurrency: true])

        _ref ->
          cache_name
      end

    {:ok, %{table: table, cache: cache}, {:continue, :load_existing}}
  end

  @impl true
  def handle_continue(:load_existing, state) do
    try do
      load_existing_usage(state.table)
    rescue
      e ->
        Logger.warning("[LLM.Budget] Initial load failed: #{Exception.message(e)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    schedule_cleanup()
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private - Budget Limit (database-driven with ETS cache)
  # ---------------------------------------------------------------------------

  @spec get_budget_limit(String.t(), keyword()) :: non_neg_integer()
  defp get_budget_limit(workspace_id, opts) do
    cache = Keyword.get(opts, :budget_cache, @budget_cache)

    case read_cached_limit(workspace_id, cache) do
      {:ok, limit} ->
        limit

      :miss ->
        limit = fetch_limit_from_db(workspace_id)
        write_cached_limit(workspace_id, limit, cache)
        limit
    end
  end

  defp read_cached_limit(workspace_id, cache) do
    case :ets.lookup(cache, {:limit, workspace_id}) do
      [{_, limit, cached_at}] ->
        age_ms = DateTime.diff(DateTime.utc_now(:second), cached_at, :millisecond)

        if age_ms < @budget_cache_ttl_ms do
          {:ok, limit}
        else
          :miss
        end

      [] ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp write_cached_limit(workspace_id, limit, cache) do
    :ets.insert(cache, {{:limit, workspace_id}, limit, DateTime.utc_now(:second)})
  rescue
    ArgumentError -> :ok
  end

  defp fetch_limit_from_db(workspace_id) do
    import Ecto.Query, warn: false

    case Repo.one(
           from(w in "workspaces",
             where: w.id == type(^workspace_id, :binary_id),
             select: w.settings
           )
         ) do
      %{"llm_budget_limit_cents" => limit} when is_integer(limit) and limit > 0 ->
        limit

      _ ->
        @default_budget_limit_cents
    end
  rescue
    _ -> @default_budget_limit_cents
  end

  defp load_existing_usage(table) do
    import Ecto.Query, warn: false

    # Load today's aggregated usage from analysis_sessions completed today
    today_start =
      DateTime.utc_now(:second) |> Map.put(:hour, 0) |> Map.put(:minute, 0) |> Map.put(:second, 0)

    results =
      Repo.all(
        from(s in "analysis_sessions",
          where: s.completed_at >= ^today_start and not is_nil(s.total_cost_cents),
          group_by: s.workspace_id,
          select: {s.workspace_id, sum(s.total_tokens_used), sum(s.total_cost_cents)}
        )
      )

    Enum.each(results, fn {workspace_id, tokens, cost} ->
      :ets.insert(table, {workspace_id, tokens || 0, cost || 0, today_start})
    end)
  rescue
    _ -> :ok
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired, :timer.hours(1))
  end
end
