defmodule SwarmshieldWeb.Admin.UsersLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "admin_role_#{System.unique_integer([:positive])}"})

    admin_perm = permission_fixture(%{resource: "admin", action: "access"})
    role_permission_fixture(role, admin_perm)

    view_perm = permission_fixture(%{resource: "settings", action: "view"})
    update_perm = permission_fixture(%{resource: "settings", action: "update"})

    role_permission_fixture(role, view_perm)
    role_permission_fixture(role, update_perm)

    user_workspace_role_fixture(user, workspace, role)

    token = Swarmshield.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:current_workspace_id, workspace.id)

    %{
      conn: conn,
      user: user,
      workspace: workspace,
      role: role,
      permissions: %{
        admin: admin_perm,
        view: view_perm,
        update: update_perm
      }
    }
  end

  defp restricted_conn(base_conn, permission_list) do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "restricted_#{System.unique_integer([:positive])}"})

    Enum.each(permission_list, fn perm ->
      role_permission_fixture(role, perm)
    end)

    user_workspace_role_fixture(user, workspace, role)

    token = Swarmshield.Accounts.generate_user_session_token(user)

    conn =
      base_conn
      |> recycle()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:current_workspace_id, workspace.id)

    {conn, workspace, user}
  end

  # ---------------------------------------------------------------------------
  # Display
  # ---------------------------------------------------------------------------

  describe "user listing" do
    test "renders manage users page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/users")

      assert html =~ "Manage Users"
      assert html =~ "member(s) in this workspace"
    end

    test "lists workspace members with roles", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/admin/users")

      assert html =~ user.email
    end

    test "shows additional members", %{conn: conn, workspace: workspace} do
      other_user = user_fixture()
      other_role = role_fixture(%{name: "viewer_#{System.unique_integer([:positive])}"})
      user_workspace_role_fixture(other_user, workspace, other_role)

      {:ok, _view, html} = live(conn, ~p"/admin/users")

      assert html =~ other_user.email
      assert html =~ "2 member(s)"
    end

    test "shows You badge for current user", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/users")

      assert html =~ "You"
    end
  end

  # ---------------------------------------------------------------------------
  # Role changes
  # ---------------------------------------------------------------------------

  describe "role changes" do
    test "changes a user's role via dropdown", %{
      conn: conn,
      workspace: workspace,
      permissions: perms
    } do
      # Create a target user in the workspace with a different role
      target_user = user_fixture()
      target_role = role_fixture(%{name: "target_role_#{System.unique_integer([:positive])}"})
      role_permission_fixture(target_role, perms.admin)
      uwr = user_workspace_role_fixture(target_user, workspace, target_role)

      # Create a new role to assign
      new_role = role_fixture(%{name: "new_role_#{System.unique_integer([:positive])}"})

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      view
      |> render_change("change_role", %{
        "uwr_id" => uwr.id,
        "role_id" => new_role.id
      })

      html = render(view)
      assert html =~ "Role updated"
    end

    test "prevents changing own role", %{conn: conn, user: user, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      # Get the current user's UWR
      uwr = Swarmshield.Accounts.get_user_workspace_role(user, workspace)
      new_role = role_fixture(%{name: "other_role_#{System.unique_integer([:positive])}"})

      view
      |> render_change("change_role", %{
        "uwr_id" => uwr.id,
        "role_id" => new_role.id
      })

      assert render(view) =~ "cannot change your own role"
    end
  end

  # ---------------------------------------------------------------------------
  # Remove user
  # ---------------------------------------------------------------------------

  describe "remove user" do
    test "removes a user from the workspace", %{conn: conn, workspace: workspace} do
      target_user = user_fixture()
      target_role = role_fixture(%{name: "removable_#{System.unique_integer([:positive])}"})
      user_workspace_role_fixture(target_user, workspace, target_role)

      {:ok, view, _html} = live(conn, ~p"/admin/users")

      assert render(view) =~ target_user.email

      view |> render_click("remove_user", %{"user_id" => target_user.id})

      html = render(view)
      assert html =~ "User removed"
      refute html =~ target_user.email
    end

    test "prevents removing yourself", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/admin/users")

      view |> render_click("remove_user", %{"user_id" => user.id})

      assert render(view) =~ "cannot remove yourself"
    end
  end

  # ---------------------------------------------------------------------------
  # Security
  # ---------------------------------------------------------------------------

  describe "security" do
    test "redirects when user lacks settings:view permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2, _user2} = restricted_conn(conn, [perms.admin])

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/admin/users")
    end

    test "rejects role change without settings:update permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, workspace2, _user2} = restricted_conn(conn, [perms.admin, perms.view])

      target_user = user_fixture()
      target_role = role_fixture(%{name: "sec_role_#{System.unique_integer([:positive])}"})
      role_permission_fixture(target_role, perms.admin)
      role_permission_fixture(target_role, perms.view)
      uwr = user_workspace_role_fixture(target_user, workspace2, target_role)

      new_role = role_fixture(%{name: "new_sec_#{System.unique_integer([:positive])}"})

      {:ok, view, _html} = live(conn2, ~p"/admin/users")

      view
      |> render_change("change_role", %{
        "uwr_id" => uwr.id,
        "role_id" => new_role.id
      })

      assert render(view) =~ "Unauthorized"
    end

    test "rejects remove without settings:update permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, workspace2, _user2} = restricted_conn(conn, [perms.admin, perms.view])

      target_user = user_fixture()
      target_role = role_fixture(%{name: "sec_rem_#{System.unique_integer([:positive])}"})
      role_permission_fixture(target_role, perms.admin)
      role_permission_fixture(target_role, perms.view)
      user_workspace_role_fixture(target_user, workspace2, target_role)

      {:ok, view, _html} = live(conn2, ~p"/admin/users")

      view |> render_click("remove_user", %{"user_id" => target_user.id})

      assert render(view) =~ "Unauthorized"
    end
  end
end
