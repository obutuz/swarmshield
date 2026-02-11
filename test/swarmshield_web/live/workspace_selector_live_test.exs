defmodule SwarmshieldWeb.WorkspaceSelectorLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures

  alias Swarmshield.Repo

  setup %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  describe "workspace selector page" do
    test "renders selector page for user with multiple workspaces", %{conn: conn, user: user} do
      workspace1 = workspace_fixture(%{name: "Alpha Workspace"})
      workspace2 = workspace_fixture(%{name: "Beta Workspace"})
      role = role_fixture(%{name: "member_#{System.unique_integer([:positive])}"})
      user_workspace_role_fixture(user, workspace1, role)
      user_workspace_role_fixture(user, workspace2, role)

      {:ok, _lv, html} = live(conn, ~p"/select-workspace")

      assert html =~ "Select Workspace"
      assert html =~ "Alpha Workspace"
      assert html =~ "Beta Workspace"
    end

    test "shows empty state with link to onboarding for user with no workspaces", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/select-workspace")

      assert html =~ "You don&#39;t belong to any workspaces yet." or
               html =~ "You don't belong to any workspaces yet."

      assert html =~ "Create a Workspace"
    end

    test "auto-selects when user has exactly 1 workspace", %{conn: conn, user: user} do
      workspace = workspace_fixture(%{name: "Only Workspace"})
      role = role_fixture(%{name: "member_#{System.unique_integer([:positive])}"})
      user_workspace_role_fixture(user, workspace, role)

      {:ok, lv, html} = live(conn, ~p"/select-workspace")

      # Should render the hidden form with phx-trigger-action for auto-selection
      assert html =~ "/set-workspace"
      assert html =~ workspace.id

      # The form should have phx-trigger-action set
      assert render(lv) =~ "phx-trigger-action"
    end

    test "clicking select sets workspace_id and triggers form submission", %{
      conn: conn,
      user: user
    } do
      workspace1 = workspace_fixture(%{name: "Workspace One"})
      workspace2 = workspace_fixture(%{name: "Workspace Two"})
      role = role_fixture(%{name: "member_#{System.unique_integer([:positive])}"})
      user_workspace_role_fixture(user, workspace1, role)
      user_workspace_role_fixture(user, workspace2, role)

      {:ok, lv, _html} = live(conn, ~p"/select-workspace")

      # Click select for workspace1
      html =
        render_click(lv, "select_workspace", %{"workspace-id" => workspace1.id})

      # Should render the hidden form with the selected workspace_id
      assert html =~ workspace1.id
      assert html =~ "/set-workspace"
      assert html =~ "phx-trigger-action"
    end

    test "redirects unauthenticated user to login" do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/select-workspace")

      assert {:redirect, %{to: path}} = redirect
      assert path =~ "/users/log-in"
    end
  end

  describe "system owner" do
    test "system owner sees all workspaces", %{conn: conn} do
      system_owner = user_fixture()

      system_owner
      |> Ecto.Changeset.change(is_system_owner: true)
      |> Repo.update!()

      # Create workspaces that the system owner is NOT a member of
      workspace_fixture(%{name: "Team Alpha"})
      workspace_fixture(%{name: "Team Beta"})

      conn =
        conn
        |> recycle()
        |> log_in_user(system_owner)

      {:ok, _lv, html} = live(conn, ~p"/select-workspace")

      assert html =~ "Team Alpha"
      assert html =~ "Team Beta"
      assert html =~ "System Owner"
    end
  end
end
