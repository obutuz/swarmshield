defmodule SwarmshieldWeb.Plugs.ApiRateLimit do
  @moduledoc """
  ETS-based sliding window rate limiter for API endpoints.
  Limits requests per IP address within a configurable time window.

  Uses :ets.update_counter/4 for atomic, lock-free increments.
  The Store GenServer owns the ETS table and runs periodic cleanup.

  ## Configuration

      config :swarmshield, SwarmshieldWeb.Plugs.ApiRateLimit,
        max_requests: 100,
        window_seconds: 60
  """

  @behaviour Plug

  import Plug.Conn

  @table :api_rate_limit
  @default_max_requests 100
  @default_window_seconds 60

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    ip = format_ip(conn.remote_ip)
    window = current_window()

    case check_rate(ip, window) do
      {:allow, count} ->
        conn
        |> put_resp_header("x-ratelimit-limit", to_string(max_requests()))
        |> put_resp_header("x-ratelimit-remaining", to_string(max(0, max_requests() - count)))

      :deny ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("x-ratelimit-limit", to_string(max_requests()))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> put_resp_header("retry-after", to_string(window_seconds()))
        |> send_resp(429, Jason.encode!(%{error: "rate_limited", message: "Too many requests"}))
        |> halt()
    end
  end

  defp check_rate(ip, window) do
    key = {ip, window}

    try do
      count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

      if count <= max_requests() do
        {:allow, count}
      else
        :deny
      end
    rescue
      ArgumentError -> {:allow, 1}
    end
  end

  defp current_window do
    System.system_time(:second) |> div(window_seconds())
  end

  defp format_ip(remote_ip) when is_tuple(remote_ip) do
    remote_ip |> :inet.ntoa() |> to_string()
  end

  defp format_ip(_), do: "unknown"

  defp max_requests do
    Application.get_env(:swarmshield, __MODULE__, [])
    |> Keyword.get(:max_requests, @default_max_requests)
  end

  defp window_seconds do
    Application.get_env(:swarmshield, __MODULE__, [])
    |> Keyword.get(:window_seconds, @default_window_seconds)
  end
end
