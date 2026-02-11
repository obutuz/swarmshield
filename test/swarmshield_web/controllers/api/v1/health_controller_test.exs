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
    test "returns 200 with status ok", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")

      assert json_response(conn, 200)["status"] == "ok"
    end

    test "returns version in response", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")

      body = json_response(conn, 200)
      assert is_binary(body["version"])
    end

    test "does not require authentication", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")
      assert conn.status == 200
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
