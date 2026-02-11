defmodule SwarmshieldWeb.SidebarNavTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()

    all_perms = create_all_permissions()

    %{conn: conn, user: user, workspace: workspace, all_perms: all_perms}
  end

  defp create_all_permissions do
    perm_specs = [
      {"admin", "access"},
      {"dashboard", "view"},
      {"events", "view"},
      {"agents", "view"},
      {"agents", "create"},
      {"agents", "update"},
      {"agents", "delete"},
      {"deliberations", "view"},
      {"ghost_protocol", "view"},
      {"ghost_protocol", "create"},
      {"ghost_protocol", "update"},
      {"ghost_protocol", "delete"},
      {"audit", "view"},
      {"audit", "export"},
      {"workflows", "view"},
      {"workflows", "create"},
      {"workflows", "update"},
      {"workflows", "delete"},
      {"policies", "view"},
      {"policies", "create"},
      {"policies", "update"},
      {"policies", "delete"},
      {"settings", "view"},
      {"settings", "update"}
    ]

    Map.new(perm_specs, fn {resource, action} ->
      perm = permission_fixture(%{resource: resource, action: action})
      {"#{resource}:#{action}", perm}
    end)
  end

  defp conn_with_permissions(base_conn, user, workspace, all_perms, permission_keys) do
    role = role_fixture(%{name: "role_#{System.unique_integer([:positive])}"})

    Enum.each(permission_keys, fn key ->
      perm = Map.fetch!(all_perms, key)
      role_permission_fixture(role, perm)
    end)

    user_workspace_role_fixture(user, workspace, role)

    token = Swarmshield.Accounts.generate_user_session_token(user)

    base_conn
    |> recycle()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:current_workspace_id, workspace.id)
  end

  describe "admin section visibility" do
    test "shows all admin items for user with full admin permissions", %{
      conn: conn,
      user: user,
      workspace: workspace,
      all_perms: all_perms
    } do
      permission_keys = [
        "admin:access",
        "dashboard:view",
        "workflows:view",
        "policies:view",
        "agents:view",
        "ghost_protocol:view",
        "settings:view"
      ]

      conn = conn_with_permissions(conn, user, workspace, all_perms, permission_keys)
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Admin"
      assert html =~ "Workflows"
      assert html =~ "Consensus Policies"
      assert html =~ "Policy Rules"
      assert html =~ "Detection Rules"
      assert html =~ "Agent Definitions"
      assert html =~ "Prompt Templates"
      assert html =~ "GhostProtocol Configs"
      assert html =~ "Registered Agents"
      assert html =~ "Settings"
      assert html =~ ">Users<"
    end

    test "hides admin section when user lacks admin:access", %{
      conn: conn,
      user: user,
      workspace: workspace,
      all_perms: all_perms
    } do
      permission_keys = [
        "dashboard:view",
        "events:view",
        "agents:view"
      ]

      conn = conn_with_permissions(conn, user, workspace, all_perms, permission_keys)
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ "Consensus Policies"
      refute html =~ "Policy Rules"
      refute html =~ "Detection Rules"
      refute html =~ "Agent Definitions"
      refute html =~ "Prompt Templates"
      refute html =~ "Registered Agents"
    end
  end

  describe "permission-based admin item visibility" do
    test "shows only workflow items when user has only workflows:view", %{
      conn: conn,
      user: user,
      workspace: workspace,
      all_perms: all_perms
    } do
      permission_keys = [
        "admin:access",
        "dashboard:view",
        "workflows:view"
      ]

      conn = conn_with_permissions(conn, user, workspace, all_perms, permission_keys)
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Workflows"
      refute html =~ "Consensus Policies"
      refute html =~ "Agent Definitions"
      refute html =~ "GhostProtocol Configs"
    end

    test "shows policy items when user has policies:view", %{
      conn: conn,
      user: user,
      workspace: workspace,
      all_perms: all_perms
    } do
      permission_keys = [
        "admin:access",
        "dashboard:view",
        "policies:view"
      ]

      conn = conn_with_permissions(conn, user, workspace, all_perms, permission_keys)
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Consensus Policies"
      assert html =~ "Policy Rules"
      assert html =~ "Detection Rules"
      refute html =~ "Workflows"
      refute html =~ "Agent Definitions"
    end
  end

  describe "ghost protocol dashboard visibility" do
    test "shows GhostProtocol sidebar link with ghost_protocol:view", %{
      conn: conn,
      user: user,
      workspace: workspace,
      all_perms: all_perms
    } do
      permission_keys = [
        "dashboard:view",
        "ghost_protocol:view"
      ]

      conn = conn_with_permissions(conn, user, workspace, all_perms, permission_keys)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "#sidebar-main-nav a[href=\"/ghost-protocol\"]")
    end

    test "hides GhostProtocol sidebar link without ghost_protocol:view", %{
      conn: conn,
      user: user,
      workspace: workspace,
      all_perms: all_perms
    } do
      permission_keys = [
        "dashboard:view"
      ]

      conn = conn_with_permissions(conn, user, workspace, all_perms, permission_keys)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      refute has_element?(view, "#sidebar-main-nav a[href=\"/ghost-protocol\"]")
    end
  end

  describe "dashboard section items" do
    test "shows core dashboard navigation items", %{
      conn: conn,
      user: user,
      workspace: workspace,
      all_perms: all_perms
    } do
      permission_keys = [
        "dashboard:view",
        "events:view",
        "agents:view",
        "deliberations:view",
        "audit:view"
      ]

      conn = conn_with_permissions(conn, user, workspace, all_perms, permission_keys)
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Dashboard"
      assert html =~ "Events"
      assert html =~ "Agents"
      assert html =~ "Deliberations"
      assert html =~ "Audit Log"
    end
  end
end
