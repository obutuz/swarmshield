defmodule SwarmshieldWeb.Plugs.RequireJsonTest do
  use SwarmshieldWeb.ConnCase, async: true

  alias SwarmshieldWeb.Plugs.RequireJson

  describe "POST/PUT/PATCH with valid Content-Type" do
    test "passes through POST with application/json", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> Map.put(:method, "POST")
        |> RequireJson.call([])

      refute conn.halted
    end

    test "passes through application/json; charset=utf-8", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json; charset=utf-8")
        |> Map.put(:method, "PUT")
        |> RequireJson.call([])

      refute conn.halted
    end

    test "passes through PATCH with application/json", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> Map.put(:method, "PATCH")
        |> RequireJson.call([])

      refute conn.halted
    end
  end

  describe "POST/PUT/PATCH with invalid Content-Type" do
    test "returns 415 for text/plain", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> Map.put(:method, "POST")
        |> RequireJson.call([])

      assert conn.halted
      assert conn.status == 415
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "unsupported_media_type"
    end

    test "returns 415 for multipart/form-data", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "multipart/form-data")
        |> Map.put(:method, "POST")
        |> RequireJson.call([])

      assert conn.halted
      assert conn.status == 415
    end

    test "returns 415 when Content-Type is missing on POST", %{conn: conn} do
      conn =
        conn
        |> Map.put(:method, "POST")
        |> RequireJson.call([])

      assert conn.halted
      assert conn.status == 415
    end
  end

  describe "GET/DELETE/OPTIONS pass through" do
    test "GET passes through without Content-Type", %{conn: conn} do
      conn = RequireJson.call(conn, [])
      refute conn.halted
    end

    test "DELETE passes through", %{conn: conn} do
      conn =
        conn
        |> Map.put(:method, "DELETE")
        |> RequireJson.call([])

      refute conn.halted
    end

    test "OPTIONS passes through", %{conn: conn} do
      conn =
        conn
        |> Map.put(:method, "OPTIONS")
        |> RequireJson.call([])

      refute conn.halted
    end
  end

  describe "init/1" do
    test "passes options through" do
      assert RequireJson.init(foo: :bar) == [foo: :bar]
    end
  end
end
