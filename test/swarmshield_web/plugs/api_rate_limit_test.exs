defmodule SwarmshieldWeb.Plugs.ApiRateLimitTest do
  use SwarmshieldWeb.ConnCase, async: false

  alias SwarmshieldWeb.Plugs.ApiRateLimit

  # async: false because rate limiter uses shared ETS table

  setup do
    # Clear ETS table between tests to prevent cross-test contamination
    try do
      :ets.delete_all_objects(:api_rate_limit)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  describe "under rate limit" do
    test "allows requests and sets rate limit headers", %{conn: conn} do
      conn = ApiRateLimit.call(conn, [])

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-limit") != []
      assert get_resp_header(conn, "x-ratelimit-remaining") != []
    end

    test "decrements remaining count on each request", %{conn: conn} do
      conn1 = ApiRateLimit.call(conn, [])
      [remaining1] = get_resp_header(conn1, "x-ratelimit-remaining")

      conn2 = build_conn() |> ApiRateLimit.call([])
      [remaining2] = get_resp_header(conn2, "x-ratelimit-remaining")

      assert String.to_integer(remaining1) > String.to_integer(remaining2)
    end
  end

  describe "exceeding rate limit" do
    setup do
      original = Application.get_env(:swarmshield, ApiRateLimit)
      Application.put_env(:swarmshield, ApiRateLimit, max_requests: 3, window_seconds: 60)

      on_exit(fn ->
        if original do
          Application.put_env(:swarmshield, ApiRateLimit, original)
        else
          Application.delete_env(:swarmshield, ApiRateLimit)
        end
      end)

      :ok
    end

    test "returns 429 after exceeding max requests", %{conn: _conn} do
      # Exhaust the limit
      Enum.each(1..3, fn _ -> build_conn() |> ApiRateLimit.call([]) end)

      # Next request should be denied
      conn = build_conn() |> ApiRateLimit.call([])

      assert conn.halted
      assert conn.status == 429

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "rate_limited"
      assert body["message"] == "Too many requests"
    end

    test "sets retry-after header on 429", %{conn: _conn} do
      Enum.each(1..3, fn _ -> build_conn() |> ApiRateLimit.call([]) end)

      conn = build_conn() |> ApiRateLimit.call([])
      assert get_resp_header(conn, "retry-after") != []
    end

    test "429 response has JSON content type", %{conn: _conn} do
      Enum.each(1..3, fn _ -> build_conn() |> ApiRateLimit.call([]) end)

      conn = build_conn() |> ApiRateLimit.call([])

      [content_type] = get_resp_header(conn, "content-type")
      assert String.contains?(content_type, "application/json")
    end
  end

  describe "per-IP isolation" do
    setup do
      original = Application.get_env(:swarmshield, ApiRateLimit)
      Application.put_env(:swarmshield, ApiRateLimit, max_requests: 2, window_seconds: 60)

      on_exit(fn ->
        if original do
          Application.put_env(:swarmshield, ApiRateLimit, original)
        else
          Application.delete_env(:swarmshield, ApiRateLimit)
        end
      end)

      :ok
    end

    test "different IPs have independent rate limits" do
      # Exhaust limit for 127.0.0.1
      Enum.each(1..2, fn _ ->
        build_conn() |> Map.put(:remote_ip, {127, 0, 0, 1}) |> ApiRateLimit.call([])
      end)

      # 127.0.0.1 should be denied
      denied = build_conn() |> Map.put(:remote_ip, {127, 0, 0, 1}) |> ApiRateLimit.call([])
      assert denied.halted
      assert denied.status == 429

      # 10.0.0.1 should still be allowed
      allowed = build_conn() |> Map.put(:remote_ip, {10, 0, 0, 1}) |> ApiRateLimit.call([])
      refute allowed.halted
    end
  end
end
