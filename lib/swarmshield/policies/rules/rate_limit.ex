defmodule Swarmshield.Policies.Rules.RateLimit do
  @moduledoc """
  Implements rate limiting evaluation using ETS-based sliding window counters.

  Tracks event counts per agent (or per workspace) within configurable time
  windows. Thresholds come from database rule config - zero hardcoded limits.

  ETS Table: `:rate_limit_counters`
  Key format: `{workspace_id, scope_id, window_start}`
  Value: `{key, count, window_start}`

  Sliding window: on each check, the current window is computed from
  `System.monotonic_time(:second)`. Expired windows are cleaned up lazily
  on read.
  """

  require Logger

  @table :rate_limit_counters

  # Maximum configurable values to prevent DoS via misconfiguration
  @max_window_seconds 86_400
  @max_events_limit 1_000_000

  @doc """
  Evaluates a rate limit rule against an event.

  Rule config format:
  ```
  %{
    "max_events" => integer,
    "window_seconds" => integer,
    "per" => "agent" | "workspace"  # optional, defaults to "agent"
  }
  ```

  Returns `{:ok, :within_limit}` or `{:violation, details}`.
  """
  def evaluate(event, rule) do
    config = rule.config

    max_events = get_config_int(config, "max_events")
    window_seconds = get_config_int(config, "window_seconds")

    cond do
      is_nil(max_events) or max_events <= 0 ->
        Logger.warning("[RateLimit] Rule #{rule.id} has invalid max_events config")
        {:ok, :within_limit}

      is_nil(window_seconds) or window_seconds <= 0 ->
        Logger.warning("[RateLimit] Rule #{rule.id} has invalid window_seconds config")
        {:ok, :within_limit}

      max_events > @max_events_limit ->
        Logger.warning("[RateLimit] Rule #{rule.id} max_events #{max_events} exceeds limit")
        {:ok, :within_limit}

      window_seconds > @max_window_seconds ->
        Logger.warning(
          "[RateLimit] Rule #{rule.id} window_seconds #{window_seconds} exceeds limit"
        )

        {:ok, :within_limit}

      true ->
        per = get_config_string(config, "per", "agent")
        check_rate(event, max_events, window_seconds, per)
    end
  end

  @doc """
  Initializes the rate limit ETS table. Called from application startup.
  """
  def init_table do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      write_concurrency: true,
      read_concurrency: true
    ])

    :ok
  rescue
    ArgumentError ->
      # Table already exists
      :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp check_rate(event, max_events, window_seconds, per) do
    workspace_id = event.workspace_id
    scope_id = scope_key(event, per)
    now = System.monotonic_time(:second)
    window_start = div(now, window_seconds) * window_seconds

    key = {workspace_id, scope_id, window_start}

    # Atomic increment - no lost updates under concurrency
    current_count =
      try do
        :ets.update_counter(@table, key, {2, 1}, {key, 0, window_start})
      rescue
        ArgumentError ->
          # ETS table not available, allow the request
          Logger.warning("[RateLimit] ETS table not available")
          0
      end

    # Clean up expired window for this scope (lazy cleanup)
    prev_window_start = window_start - window_seconds
    prev_key = {workspace_id, scope_id, prev_window_start}

    try do
      :ets.delete(@table, prev_key)
    rescue
      ArgumentError -> :ok
    end

    if current_count > max_events do
      {:violation,
       %{
         current_count: current_count,
         max_events: max_events,
         window_seconds: window_seconds,
         per: per
       }}
    else
      {:ok, :within_limit}
    end
  end

  defp scope_key(event, "workspace"), do: event.workspace_id
  defp scope_key(event, _per_agent), do: event.registered_agent_id

  defp get_config_int(config, key) do
    value = config[key] || config[String.to_existing_atom(key)]

    case value do
      v when is_integer(v) -> v
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp get_config_string(config, key, default) do
    value = config[key] || config[String.to_existing_atom(key)]

    case value do
      v when is_binary(v) -> v
      _ -> default
    end
  rescue
    ArgumentError -> default
  end
end
