defmodule SwarmshieldWeb.Api.V1.EventControllerTest do
  use SwarmshieldWeb.ConnCase, async: false

  import Ecto.Query

  alias Swarmshield.Gateway.ApiKeyCache
  alias Swarmshield.Gateway.RegisteredAgent
  alias Swarmshield.Repo

  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures

  # async: false because ApiKeyCache uses shared ETS table

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Swarmshield.TaskSupervisor),
          is_pid(pid) do
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          500 -> :ok
        end
      end
    end)

    try do
      :ets.delete_all_objects(:api_rate_limit)
    rescue
      ArgumentError -> :ok
    end

    workspace = workspace_fixture()
    {raw_key, agent} = create_agent_with_raw_key(workspace)
    %{workspace: workspace, agent: agent, raw_key: raw_key}
  end

  describe "POST /api/v1/events - success" do
    test "creates event and returns 201", %{conn: conn, raw_key: raw_key} do
      params = %{
        "event_type" => "action",
        "content" => "Agent performed search query",
        "severity" => "info"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert %{"data" => data} = json_response(conn, 201)
      assert data["event_type"] == "action"
      assert data["content"] == "Agent performed search query"
      assert data["severity"] == "info"
      assert data["status"] == "pending"
      assert data["id"] != nil
      assert data["inserted_at"] != nil
    end

    test "sets source_ip from connection", %{conn: conn, raw_key: raw_key} do
      params = %{"event_type" => "action", "content" => "Test event"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      assert data["source_ip"] != nil
    end

    test "accepts optional payload map", %{conn: conn, raw_key: raw_key} do
      params = %{
        "event_type" => "tool_call",
        "content" => "Called external API",
        "payload" => %{"url" => "https://api.example.com", "method" => "GET"}
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      assert data["payload"]["url"] == "https://api.example.com"
    end

    test "ignores unknown fields in body", %{conn: conn, raw_key: raw_key} do
      params = %{
        "event_type" => "action",
        "content" => "Test",
        "evil_field" => "injection",
        "workspace_id" => "fake-id",
        "status" => "allowed"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      assert data["status"] == "pending"
      refute Map.has_key?(data, "evil_field")
    end

    test "does not expose workspace_id in response", %{conn: conn, raw_key: raw_key} do
      params = %{"event_type" => "action", "content" => "Test"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      refute Map.has_key?(data, "workspace_id")
    end
  end

  describe "POST /api/v1/events - validation errors" do
    test "returns 422 when event_type is missing", %{conn: conn, raw_key: raw_key} do
      params = %{"content" => "Missing event type"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["event_type"] != nil
    end

    test "returns 422 when content is missing", %{conn: conn, raw_key: raw_key} do
      params = %{"event_type" => "action"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["content"] != nil
    end

    test "returns 422 for invalid event_type enum", %{conn: conn, raw_key: raw_key} do
      params = %{"event_type" => "nonexistent_type", "content" => "Test"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert json_response(conn, 422)
    end

    test "returns 422 when both required fields are missing", %{conn: conn, raw_key: raw_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", %{})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["event_type"] != nil
      assert errors["content"] != nil
    end
  end

  describe "POST /api/v1/events - authentication" do
    test "returns 401 without auth token", %{conn: conn} do
      params = %{"event_type" => "action", "content" => "Test"}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert json_response(conn, 401)
    end

    test "returns 401 with invalid token", %{conn: conn} do
      params = %{"event_type" => "action", "content" => "Test"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid-token")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/v1/events - content type" do
    test "returns 415 without Content-Type header", %{conn: conn, raw_key: raw_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/events", %{})

      assert conn.status == 415
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_agent_with_raw_key(workspace) do
    {raw_key, hash, prefix} = RegisteredAgent.generate_api_key()

    agent = registered_agent_fixture(%{workspace_id: workspace.id})

    from(a in RegisteredAgent, where: a.id == ^agent.id)
    |> Repo.update_all(set: [api_key_hash: hash, api_key_prefix: prefix])

    ApiKeyCache.invalidate_agent(agent.id)

    updated_agent = Repo.get!(RegisteredAgent, agent.id)
    {raw_key, updated_agent}
  end
end
