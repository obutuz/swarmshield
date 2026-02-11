defmodule SwarmshieldWeb.Plugs.ApiAuthTest do
  use SwarmshieldWeb.ConnCase, async: false

  import Ecto.Query

  alias Swarmshield.Accounts.AuditEntry
  alias Swarmshield.Gateway.ApiKeyCache
  alias Swarmshield.Gateway.RegisteredAgent
  alias Swarmshield.Repo
  alias SwarmshieldWeb.Plugs.ApiAuth

  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures

  # async: false because ApiKeyCache uses shared ETS table

  setup do
    # Drain TaskSupervisor children before sandbox teardown.
    # on_exit runs LIFO: this callback (registered second) runs BEFORE
    # ConnCase's sandbox teardown (registered first), preventing
    # Postgrex disconnect errors from async fire-and-forget tasks.
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

    workspace = workspace_fixture()
    %{workspace: workspace}
  end

  describe "valid authentication" do
    test "authenticates with valid Bearer token and assigns agent + workspace", %{
      conn: conn,
      workspace: workspace
    } do
      {raw_key, agent} = create_agent_with_raw_key(workspace)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> ApiAuth.call([])

      refute conn.halted
      assert conn.assigns.current_agent.agent_id == agent.id
      assert conn.assigns.current_agent.workspace_id == workspace.id
      assert conn.assigns.current_agent.status == :active
      assert conn.assigns.current_workspace.id == workspace.id
    end

    test "handles 'bearer' in lowercase", %{conn: conn, workspace: workspace} do
      {raw_key, _agent} = create_agent_with_raw_key(workspace)

      conn =
        conn
        |> put_req_header("authorization", "bearer #{raw_key}")
        |> ApiAuth.call([])

      refute conn.halted
      assert conn.assigns[:current_agent]
    end

    test "handles 'BEARER' in uppercase", %{conn: conn, workspace: workspace} do
      {raw_key, _agent} = create_agent_with_raw_key(workspace)

      conn =
        conn
        |> put_req_header("authorization", "BEARER #{raw_key}")
        |> ApiAuth.call([])

      refute conn.halted
      assert conn.assigns[:current_agent]
    end

    test "trims extra whitespace from token", %{conn: conn, workspace: workspace} do
      {raw_key, _agent} = create_agent_with_raw_key(workspace)

      conn =
        conn
        |> put_req_header("authorization", "Bearer   #{raw_key}  ")
        |> ApiAuth.call([])

      refute conn.halted
      assert conn.assigns[:current_agent]
    end

    test "schedules async last_seen_at update", %{conn: conn, workspace: workspace} do
      {raw_key, agent} = create_agent_with_raw_key(workspace)

      conn
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> ApiAuth.call([])

      # Wait for async task to complete
      Process.sleep(100)

      updated_agent = Swarmshield.Repo.get!(RegisteredAgent, agent.id)
      assert updated_agent.last_seen_at != nil
    end
  end

  describe "missing authorization header" do
    test "returns 401 when Authorization header is missing", %{conn: conn} do
      conn = ApiAuth.call(conn, [])

      assert conn.halted
      assert conn.status == 401

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "missing_credentials"
      assert body["message"] == "Authentication required"
    end
  end

  describe "invalid authorization header format" do
    test "returns 401 for Authorization without Bearer prefix", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Basic some-token")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_credentials"
    end

    test "returns 401 for empty Authorization header value", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 for 'Bearer' with no token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer ")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 for just 'Bearer' without space", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "invalid token" do
    test "returns 401 with generic 'invalid_credentials' for non-existent token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer totally-fake-token-12345")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 401

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_credentials"
      assert body["message"] == "Authentication required"
    end

    test "does not differentiate agent-not-found vs invalid-token", %{conn: _conn} do
      # Both should return the same generic error
      conn1 =
        build_conn()
        |> put_req_header("authorization", "Bearer completely-invalid-key")
        |> ApiAuth.call([])

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer another-invalid-key-here")
        |> ApiAuth.call([])

      body1 = Jason.decode!(conn1.resp_body)
      body2 = Jason.decode!(conn2.resp_body)

      assert body1["error"] == body2["error"]
      assert body1["message"] == body2["message"]
      assert conn1.status == conn2.status
    end
  end

  describe "suspended agent" do
    test "returns 403 with 'agent_suspended' for suspended agent", %{
      conn: conn,
      workspace: workspace
    } do
      {raw_key, _agent} = create_agent_with_raw_key(workspace, %{status: :suspended})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 403

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "agent_suspended"
      assert body["message"] == "Access denied"
    end
  end

  describe "revoked agent" do
    test "returns 403 with 'agent_revoked' for revoked agent", %{
      conn: conn,
      workspace: workspace
    } do
      {raw_key, _agent} = create_agent_with_raw_key(workspace, %{status: :revoked})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 403

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "agent_revoked"
    end
  end

  describe "workspace status checks" do
    test "returns 403 for agent in archived workspace", %{conn: conn} do
      workspace =
        workspace_fixture(%{status: :archived})

      {raw_key, _agent} = create_agent_with_raw_key(workspace)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 403

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "workspace_archived"
    end

    test "returns 403 for agent in suspended workspace", %{conn: conn} do
      workspace =
        workspace_fixture(%{status: :suspended})

      {raw_key, _agent} = create_agent_with_raw_key(workspace)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> ApiAuth.call([])

      assert conn.halted
      assert conn.status == 403

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "workspace_suspended"
    end
  end

  describe "audit trail" do
    test "creates audit entry for failed authentication", %{conn: conn} do
      initial_count = audit_entry_count()

      conn
      |> put_req_header("authorization", "Bearer invalid-token-for-audit")
      |> ApiAuth.call([])

      # Wait for async audit task
      Process.sleep(100)

      assert audit_entry_count() > initial_count
    end

    test "audit entry includes IP address and reason", %{conn: conn} do
      conn
      |> put_req_header("authorization", "Bearer audit-test-token")
      |> ApiAuth.call([])

      # Wait for async audit task
      Process.sleep(100)

      entry = last_audit_entry()
      assert entry.action == "api_auth.failed"
      assert entry.resource_type == "api_authentication"
      assert entry.ip_address != nil
      assert entry.metadata["reason"] != nil
    end
  end

  describe "response format" do
    test "401 responses have application/json content type", %{conn: conn} do
      conn = ApiAuth.call(conn, [])

      assert conn.status == 401
      [content_type] = get_resp_header(conn, "content-type")
      assert String.contains?(content_type, "application/json")
    end

    test "403 responses have application/json content type", %{
      conn: conn,
      workspace: workspace
    } do
      {raw_key, _agent} = create_agent_with_raw_key(workspace, %{status: :suspended})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> ApiAuth.call([])

      assert conn.status == 403
      [content_type] = get_resp_header(conn, "content-type")
      assert String.contains?(content_type, "application/json")
    end
  end

  describe "init/1" do
    test "passes options through unchanged" do
      assert ApiAuth.init(foo: :bar) == [foo: :bar]
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_agent_with_raw_key(workspace, attrs \\ %{}) do
    {raw_key, hash, prefix} = RegisteredAgent.generate_api_key()

    agent =
      registered_agent_fixture(
        Map.merge(
          %{workspace_id: workspace.id},
          attrs
        )
      )

    agent_id = agent.id

    # Update the agent to use our known key hash
    from(a in RegisteredAgent, where: a.id == ^agent_id)
    |> Repo.update_all(set: [api_key_hash: hash, api_key_prefix: prefix])

    # Invalidate cache so next lookup goes to DB with updated hash
    ApiKeyCache.invalidate_agent(agent_id)

    updated_agent = Repo.get!(RegisteredAgent, agent_id)

    {raw_key, updated_agent}
  end

  defp audit_entry_count do
    Repo.aggregate(from(_a in AuditEntry), :count)
  end

  defp last_audit_entry do
    Repo.one(
      from(a in AuditEntry,
        order_by: [desc: a.inserted_at],
        limit: 1
      )
    )
  end
end
