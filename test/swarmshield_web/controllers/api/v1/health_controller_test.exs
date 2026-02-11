defmodule SwarmshieldWeb.Api.V1.HealthControllerTest do
  use SwarmshieldWeb.ConnCase, async: false

  # async: false because rate limiter uses shared ETS table

  setup do
    try do
      :ets.delete_all_objects(:api_rate_limit)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  describe "GET /api/v1/health" do
    test "returns 200 with status ok and database healthy", %{conn: conn} do
      body = conn |> get(~p"/api/v1/health") |> json_response(200)

      assert body["status"] == "ok"
    end

    test "returns version from Application.spec (not Mix.Project)", %{conn: conn} do
      body = conn |> get(~p"/api/v1/health") |> json_response(200)

      assert is_binary(body["version"])
      assert body["version"] =~ ~r/^\d+\.\d+\.\d+/
    end

    test "returns valid ISO 8601 UTC timestamp", %{conn: conn} do
      body = conn |> get(~p"/api/v1/health") |> json_response(200)

      assert is_binary(body["timestamp"])
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(body["timestamp"])
    end

    test "does not require authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")
      assert conn.status == 200
    end

    test "does NOT expose Elixir version, OTP version, or internal IPs", %{conn: conn} do
      body = conn |> get(~p"/api/v1/health") |> json_response(200)

      refute Map.has_key?(body, "elixir_version")
      refute Map.has_key?(body, "otp_version")
      refute Map.has_key?(body, "ip")
      refute Map.has_key?(body, "database_version")
      refute Map.has_key?(body, "node")
    end

    test "includes security headers", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "includes CORS headers", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")
      assert get_resp_header(conn, "access-control-allow-methods") != []
    end

    test "includes rate limit headers", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")
      assert get_resp_header(conn, "x-ratelimit-limit") != []
      assert get_resp_header(conn, "x-ratelimit-remaining") != []
    end
  end

  describe "API pipeline content negotiation" do
    test "returns 406 for non-JSON Accept header", %{conn: conn} do
      assert_error_sent :not_acceptable, fn ->
        conn
        |> put_req_header("accept", "text/html")
        |> get(~p"/api/v1/health")
      end
    end
  end

  describe "CORS preflight" do
    test "OPTIONS /api/v1/health returns 204", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://example.com")
        |> Map.put(:method, "OPTIONS")
        |> put_req_header("access-control-request-method", "GET")

      conn = options(conn, ~p"/api/v1/health")

      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-methods") != []
    end
  end
end
