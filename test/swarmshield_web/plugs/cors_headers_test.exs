defmodule SwarmshieldWeb.Plugs.CorsHeadersTest do
  use SwarmshieldWeb.ConnCase, async: true

  alias SwarmshieldWeb.Plugs.CorsHeaders

  describe "non-OPTIONS requests" do
    test "sets CORS headers without halting", %{conn: conn} do
      conn = CorsHeaders.call(conn, [])

      refute conn.halted
      assert get_resp_header(conn, "access-control-allow-methods") != []
      assert get_resp_header(conn, "access-control-allow-headers") != []
      assert get_resp_header(conn, "access-control-max-age") != []
    end
  end

  describe "OPTIONS preflight" do
    test "returns 204 and halts for OPTIONS request", %{conn: conn} do
      conn =
        conn
        |> Map.put(:method, "OPTIONS")
        |> CorsHeaders.call([])

      assert conn.halted
      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-methods") != []
    end
  end

  describe "origin matching with no config (default)" do
    test "returns empty origin when no allowed_origins configured", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://example.com")
        |> CorsHeaders.call([])

      [origin] = get_resp_header(conn, "access-control-allow-origin")
      assert origin == ""
    end
  end

  describe "origin matching with wildcard config" do
    setup do
      original = Application.get_env(:swarmshield, CorsHeaders)

      Application.put_env(:swarmshield, CorsHeaders, allowed_origins: ["*"])

      on_exit(fn ->
        if original do
          Application.put_env(:swarmshield, CorsHeaders, original)
        else
          Application.delete_env(:swarmshield, CorsHeaders)
        end
      end)

      :ok
    end

    test "returns * when configured with wildcard", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://example.com")
        |> CorsHeaders.call([])

      [origin] = get_resp_header(conn, "access-control-allow-origin")
      assert origin == "*"
    end

    test "does not set Vary: Origin header for wildcard", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://example.com")
        |> CorsHeaders.call([])

      assert get_resp_header(conn, "vary") == []
    end
  end

  describe "origin matching with specific origins" do
    setup do
      original = Application.get_env(:swarmshield, CorsHeaders)

      Application.put_env(:swarmshield, CorsHeaders,
        allowed_origins: ["https://app.swarmshield.io", "https://admin.swarmshield.io"]
      )

      on_exit(fn ->
        if original do
          Application.put_env(:swarmshield, CorsHeaders, original)
        else
          Application.delete_env(:swarmshield, CorsHeaders)
        end
      end)

      :ok
    end

    test "reflects matching origin", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://app.swarmshield.io")
        |> CorsHeaders.call([])

      [origin] = get_resp_header(conn, "access-control-allow-origin")
      assert origin == "https://app.swarmshield.io"
    end

    test "sets Vary: Origin for specific origin matches", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://app.swarmshield.io")
        |> CorsHeaders.call([])

      assert get_resp_header(conn, "vary") == ["origin"]
    end

    test "sets Vary: Origin even for non-matching origin", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://evil.com")
        |> CorsHeaders.call([])

      assert get_resp_header(conn, "vary") == ["origin"]
    end

    test "returns empty string for non-matching origin", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://evil.com")
        |> CorsHeaders.call([])

      [origin] = get_resp_header(conn, "access-control-allow-origin")
      assert origin == ""
    end
  end
end
