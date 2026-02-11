defmodule SwarmshieldWeb.Admin.SettingsLiveTest do
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

    {conn, workspace}
  end

  # ---------------------------------------------------------------------------
  # Display
  # ---------------------------------------------------------------------------

  describe "settings display" do
    test "renders workspace settings page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/settings")

      assert html =~ "Workspace Settings"
      assert html =~ "General"
      assert html =~ "Deliberation Defaults"
      assert html =~ "API Key"
    end

    test "shows workspace name and slug in form", %{conn: conn, workspace: workspace} do
      {:ok, _view, html} = live(conn, ~p"/admin/settings")

      assert html =~ workspace.name
      assert html =~ workspace.slug
    end

    test "shows API key prefix", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/settings")

      # Initially no key generated for test workspace
      assert html =~ "Not generated"
    end
  end

  # ---------------------------------------------------------------------------
  # General settings
  # ---------------------------------------------------------------------------

  describe "general settings" do
    test "updates workspace name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      view
      |> form("#workspace-settings-form", %{
        workspace: %{name: "Updated Workspace Name"}
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Workspace settings saved."
      assert html =~ "Updated Workspace Name"
    end

    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert view
             |> form("#workspace-settings-form", %{workspace: %{name: ""}})
             |> render_change() =~ "can&#39;t be blank"
    end
  end

  # ---------------------------------------------------------------------------
  # Deliberation settings
  # ---------------------------------------------------------------------------

  describe "deliberation settings" do
    test "saves deliberation settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      view
      |> form("#deliberation-settings-form", %{
        default_timeout: "600",
        max_rounds: "5"
      })
      |> render_submit()

      assert render(view) =~ "Deliberation settings saved."
    end
  end

  # ---------------------------------------------------------------------------
  # API key
  # ---------------------------------------------------------------------------

  describe "api key management" do
    test "regenerates API key and shows it once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      view |> render_click("regenerate_api_key")

      html = render(view)
      assert html =~ "API key regenerated"
      assert html =~ "swrm_"
      assert html =~ "copy it now"
    end

    test "dismisses generated key display", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      view |> render_click("regenerate_api_key")
      assert render(view) =~ "swrm_"

      view |> render_click("dismiss_key")
      refute render(view) =~ "copy it now"
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
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin])

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/admin/settings")
    end

    test "rejects save without settings:update permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, view, _html} = live(conn2, ~p"/admin/settings")

      view
      |> form("#workspace-settings-form", %{
        workspace: %{name: "Sneaky Name"}
      })
      |> render_submit()

      assert render(view) =~ "Unauthorized"
    end

    test "rejects API key regeneration without settings:update permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, view, _html} = live(conn2, ~p"/admin/settings")

      view |> render_click("regenerate_api_key")

      assert render(view) =~ "Unauthorized"
    end
  end
end
