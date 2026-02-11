defmodule SwarmshieldWeb.Plugs.ApiSecurityHeadersTest do
  use SwarmshieldWeb.ConnCase, async: true

  alias SwarmshieldWeb.Plugs.ApiSecurityHeaders

  test "sets X-Content-Type-Options: nosniff", %{conn: conn} do
    conn = ApiSecurityHeaders.call(conn, [])

    [value] = get_resp_header(conn, "x-content-type-options")
    assert value == "nosniff"
  end

  test "sets X-Frame-Options: DENY", %{conn: conn} do
    conn = ApiSecurityHeaders.call(conn, [])

    [value] = get_resp_header(conn, "x-frame-options")
    assert value == "DENY"
  end

  test "sets Cache-Control: no-store", %{conn: conn} do
    conn = ApiSecurityHeaders.call(conn, [])

    [value] = get_resp_header(conn, "cache-control")
    assert value == "no-store"
  end

  test "does not halt the connection", %{conn: conn} do
    conn = ApiSecurityHeaders.call(conn, [])
    refute conn.halted
  end
end
