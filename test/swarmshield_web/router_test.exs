defmodule SwarmshieldWeb.RouterTest do
  @moduledoc """
  Tests verifying route accessibility for different authentication states and roles.
  """
  use SwarmshieldWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures

  alias Swarmshield.Accounts

  # --- Helper to set up a user with a workspace and role ---

  defp setup_workspace_user(user, role_name) do
    :ok = Accounts.ensure_default_roles_and_permissions()
    workspace = workspace_fixture()
    role = Accounts.get_role_by_name(role_name)
    {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)
    workspace
  end

  describe "public routes" do
    test "home page is accessible without auth", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Phoenix"
    end

    test "login page is accessible without auth", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/log-in")
      assert html =~ "Log in"
    end

    test "register page is accessible without auth", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")
      assert html =~ "Register"
    end
  end

  describe "authenticated routes (no workspace)" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      %{conn: conn, user: user}
    end

    test "settings page is accessible", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/settings")
      assert html =~ "Settings"
    end

    test "onboarding page is accessible for user without workspace", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/onboarding")
      assert html =~ "Create Your Workspace"
    end

    test "workspace selector page is accessible", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/select-workspace")
      assert html =~ "Select Workspace"
    end
  end

  describe "unauthenticated access to protected routes" do
    test "settings redirects to login", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end

    test "onboarding redirects to login", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/onboarding")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end

    test "select-workspace redirects to login", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/select-workspace")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end

    test "dashboard redirects to login", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/dashboard")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end

    test "admin settings redirects to login", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/admin/settings")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end
  end

  describe "workspace-authenticated routes" do
    setup %{conn: conn} do
      user = user_fixture()
      workspace = setup_workspace_user(user, "super_admin")
      conn = log_in_user(conn, user)

      # Set the workspace in the session
      conn =
        conn
        |> recycle()
        |> Map.replace!(:secret_key_base, SwarmshieldWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{
          user_token: get_session(conn, :user_token),
          current_workspace_id: workspace.id
        })

      %{conn: conn, user: user, workspace: workspace}
    end

    test "dashboard is accessible with workspace", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ "Dashboard"
    end

    test "events page is accessible with workspace", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/events")
      assert html =~ "Events"
    end

    test "agents page is accessible with workspace", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/agents")
      assert html =~ "Agents"
    end

    test "deliberations page is accessible with workspace", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/deliberations")
      assert html =~ "Deliberations"
    end

    test "audit page is accessible with workspace", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/audit")
      assert html =~ "Audit Log"
    end
  end

  describe "workspace routes without workspace in session" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      %{conn: conn, user: user}
    end

    test "dashboard redirects to select-workspace", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/dashboard")
      assert {:redirect, %{to: "/select-workspace"}} = redirect
    end

    test "events redirects to select-workspace", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/events")
      assert {:redirect, %{to: "/select-workspace"}} = redirect
    end

    test "admin settings redirects to select-workspace", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/admin/settings")
      assert {:redirect, %{to: "/select-workspace"}} = redirect
    end
  end

  describe "admin routes with admin permission" do
    setup %{conn: conn} do
      user = user_fixture()
      workspace = setup_workspace_user(user, "admin")
      conn = log_in_user(conn, user)

      conn =
        conn
        |> recycle()
        |> Map.replace!(:secret_key_base, SwarmshieldWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{
          user_token: get_session(conn, :user_token),
          current_workspace_id: workspace.id
        })

      %{conn: conn, user: user, workspace: workspace}
    end

    test "admin settings is accessible for admin", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/settings")
      assert html =~ "Workspace Settings"
    end

    test "admin roles is accessible for admin", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/roles")
      assert html =~ "Manage Roles"
    end

    test "admin users is accessible for admin", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/admin/users")
      assert html =~ "Manage Users"
    end
  end

  describe "admin routes without admin permission" do
    setup %{conn: conn} do
      user = user_fixture()
      workspace = setup_workspace_user(user, "viewer")
      conn = log_in_user(conn, user)

      conn =
        conn
        |> recycle()
        |> Map.replace!(:secret_key_base, SwarmshieldWeb.Endpoint.config(:secret_key_base))
        |> init_test_session(%{
          user_token: get_session(conn, :user_token),
          current_workspace_id: workspace.id
        })

      %{conn: conn, user: user, workspace: workspace}
    end

    test "admin settings is denied for viewer", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/admin/settings")
      assert {:redirect, %{to: "/"}} = redirect
    end

    test "admin roles is denied for viewer", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/admin/roles")
      assert {:redirect, %{to: "/"}} = redirect
    end
  end

  describe "security" do
    test "browser pipeline includes CSRF protection", %{conn: conn} do
      # Verify the pipeline is configured (CSRF token is present in responses)
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "csrf-token"
    end
  end
end
