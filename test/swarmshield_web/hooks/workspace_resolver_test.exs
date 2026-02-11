defmodule SwarmshieldWeb.Hooks.WorkspaceResolverTest do
  use SwarmshieldWeb.ConnCase, async: false

  alias Swarmshield.Accounts
  alias Swarmshield.Accounts.Scope
  alias SwarmshieldWeb.Hooks.WorkspaceResolver

  import Swarmshield.AccountsFixtures

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, SwarmshieldWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{conn: conn}
  end

  describe "resolve_and_redirect/2" do
    test "redirects to /onboarding when user has 0 workspaces", %{conn: conn} do
      user = user_fixture()

      conn = WorkspaceResolver.resolve_and_redirect(conn, user)

      assert redirected_to(conn) == "/onboarding"
    end

    test "sets workspace_id in session and redirects to /dashboard for 1 workspace", %{
      conn: conn
    } do
      user = user_fixture()
      workspace = workspace_fixture()
      role = role_fixture(%{name: "test_role"})
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)

      conn = WorkspaceResolver.resolve_and_redirect(conn, user)

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :current_workspace_id) == workspace.id
    end

    test "redirects to /select-workspace when user has 2+ workspaces", %{conn: conn} do
      user = user_fixture()
      role = role_fixture(%{name: "multi_role"})

      workspace1 = workspace_fixture()
      workspace2 = workspace_fixture()
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace1, role)
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace2, role)

      conn = WorkspaceResolver.resolve_and_redirect(conn, user)

      assert redirected_to(conn) == "/select-workspace"
    end
  end

  describe "call/2 (Plug interface)" do
    test "passes through when no workspace_id in session", %{conn: conn} do
      user = user_fixture()
      scope = Scope.for_user(user)

      conn =
        conn
        |> assign(:current_scope, scope)
        |> WorkspaceResolver.call([])

      refute conn.halted
    end

    test "passes through when workspace is valid and user is member", %{conn: conn} do
      user = user_fixture()
      workspace = workspace_fixture()
      role = role_fixture(%{name: "valid_role"})
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)
      scope = Scope.for_user(user)

      conn =
        conn
        |> assign(:current_scope, scope)
        |> put_session(:current_workspace_id, workspace.id)
        |> WorkspaceResolver.call([])

      refute conn.halted
    end

    test "redirects when workspace is suspended", %{conn: conn} do
      user = user_fixture()
      workspace = workspace_fixture()
      role = role_fixture(%{name: "sus_role"})
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)
      {:ok, _suspended} = Accounts.update_workspace(workspace, %{status: :suspended})
      scope = Scope.for_user(user)

      conn =
        conn
        |> assign(:current_scope, scope)
        |> put_session(:current_workspace_id, workspace.id)
        |> fetch_flash()
        |> WorkspaceResolver.call([])

      assert conn.halted
      assert redirected_to(conn) == "/select-workspace"
      refute get_session(conn, :current_workspace_id)
    end

    test "redirects when workspace is archived", %{conn: conn} do
      user = user_fixture()
      workspace = workspace_fixture()
      role = role_fixture(%{name: "arc_role"})
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)
      {:ok, _archived} = Accounts.update_workspace(workspace, %{status: :archived})
      scope = Scope.for_user(user)

      conn =
        conn
        |> assign(:current_scope, scope)
        |> put_session(:current_workspace_id, workspace.id)
        |> fetch_flash()
        |> WorkspaceResolver.call([])

      assert conn.halted
      assert redirected_to(conn) == "/select-workspace"
      refute get_session(conn, :current_workspace_id)
    end

    test "redirects when workspace no longer exists", %{conn: conn} do
      user = user_fixture()
      scope = Scope.for_user(user)
      fake_workspace_id = Ecto.UUID.generate()

      conn =
        conn
        |> assign(:current_scope, scope)
        |> put_session(:current_workspace_id, fake_workspace_id)
        |> WorkspaceResolver.call([])

      assert conn.halted
      assert redirected_to(conn) == "/select-workspace"
      refute get_session(conn, :current_workspace_id)
    end

    test "redirects when user removed from workspace", %{conn: conn} do
      user = user_fixture()
      workspace = workspace_fixture()
      role = role_fixture(%{name: "rem_role"})
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)
      :ok = Accounts.remove_user_from_workspace(user, workspace)
      scope = Scope.for_user(user)

      conn =
        conn
        |> assign(:current_scope, scope)
        |> put_session(:current_workspace_id, workspace.id)
        |> fetch_flash()
        |> WorkspaceResolver.call([])

      assert conn.halted
      assert redirected_to(conn) == "/select-workspace"
      refute get_session(conn, :current_workspace_id)
    end

    test "passes through when no current_scope", %{conn: conn} do
      conn =
        conn
        |> put_session(:current_workspace_id, Ecto.UUID.generate())
        |> WorkspaceResolver.call([])

      refute conn.halted
    end
  end

  describe "integration with log_in_user" do
    test "user with 0 workspaces is redirected to /onboarding", %{conn: conn} do
      user = user_fixture()
      conn = assign(conn, :current_scope, Scope.for_user(user))

      conn = SwarmshieldWeb.UserAuth.log_in_user(conn, user)

      assert redirected_to(conn) == "/onboarding"
    end

    test "user with 1 workspace gets workspace_id in session", %{conn: conn} do
      user = user_fixture()
      workspace = workspace_fixture()
      role = role_fixture(%{name: "int_role"})
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)
      conn = assign(conn, :current_scope, Scope.for_user(user))

      conn = SwarmshieldWeb.UserAuth.log_in_user(conn, user)

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :current_workspace_id) == workspace.id
    end

    test "user with 2+ workspaces is redirected to /select-workspace", %{conn: conn} do
      user = user_fixture()
      role = role_fixture(%{name: "int_multi_role"})
      w1 = workspace_fixture()
      w2 = workspace_fixture()
      {:ok, _} = Accounts.assign_user_to_workspace(user, w1, role)
      {:ok, _} = Accounts.assign_user_to_workspace(user, w2, role)
      conn = assign(conn, :current_scope, Scope.for_user(user))

      conn = SwarmshieldWeb.UserAuth.log_in_user(conn, user)

      assert redirected_to(conn) == "/select-workspace"
    end

    test "user_return_to is preserved through workspace resolution for single workspace", %{
      conn: conn
    } do
      user = user_fixture()
      workspace = workspace_fixture()
      role = role_fixture(%{name: "resolver_rto_#{System.unique_integer([:positive])}"})
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)
      conn = assign(conn, :current_scope, Scope.for_user(user))

      conn =
        conn
        |> put_session(:user_return_to, "/custom-path")
        |> SwarmshieldWeb.UserAuth.log_in_user(user)

      # Single workspace: auto-select + redirect to user_return_to
      assert redirected_to(conn) == "/custom-path"
      assert get_session(conn, :current_workspace_id) == workspace.id
    end

    test "user_return_to no longer bypasses workspace resolution for zero workspaces", %{
      conn: conn
    } do
      user = user_fixture()
      conn = assign(conn, :current_scope, Scope.for_user(user))

      conn =
        conn
        |> put_session(:user_return_to, "/custom-path")
        |> SwarmshieldWeb.UserAuth.log_in_user(user)

      # No workspaces: always onboarding, regardless of user_return_to
      assert redirected_to(conn) == "/onboarding"
    end
  end
end
