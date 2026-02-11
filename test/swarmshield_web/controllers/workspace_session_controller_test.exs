defmodule SwarmshieldWeb.WorkspaceSessionControllerTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Swarmshield.AccountsFixtures
  alias Swarmshield.Repo

  setup do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "member_#{System.unique_integer([:positive])}"})
    user_workspace_role_fixture(user, workspace, role)

    %{user: user, workspace: workspace, role: role}
  end

  describe "POST /set-workspace" do
    test "sets workspace in session and redirects to dashboard", %{
      conn: conn,
      user: user,
      workspace: workspace
    } do
      conn =
        conn
        |> log_in_user(user)
        |> post("/set-workspace", %{"workspace_id" => workspace.id})

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :current_workspace_id) == workspace.id
    end

    test "redirects to user_return_to when set in session", %{
      conn: conn,
      user: user,
      workspace: workspace
    } do
      conn =
        conn
        |> log_in_user(user)
        |> put_session(:user_return_to, "/events")
        |> post("/set-workspace", %{"workspace_id" => workspace.id})

      assert redirected_to(conn) == "/events"
      assert get_session(conn, :current_workspace_id) == workspace.id
      # user_return_to should be cleared after use
      refute get_session(conn, :user_return_to)
    end

    test "rejects invalid UUID", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> post("/set-workspace", %{"workspace_id" => "not-a-uuid"})

      assert redirected_to(conn) == "/select-workspace"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid workspace."
      refute get_session(conn, :current_workspace_id)
    end

    test "rejects nonexistent workspace", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> post("/set-workspace", %{"workspace_id" => Ecto.UUID.generate()})

      assert redirected_to(conn) == "/select-workspace"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Workspace not found."
    end

    test "rejects workspace user is not a member of", %{conn: conn, user: user} do
      other_workspace = workspace_fixture(%{name: "Other Workspace"})

      conn =
        conn
        |> log_in_user(user)
        |> post("/set-workspace", %{"workspace_id" => other_workspace.id})

      assert redirected_to(conn) == "/select-workspace"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You are not a member of this workspace."
    end

    test "rejects suspended workspace", %{conn: conn, user: user, workspace: workspace} do
      workspace
      |> Ecto.Changeset.change(status: :suspended)
      |> Repo.update!()

      conn =
        conn
        |> log_in_user(user)
        |> post("/set-workspace", %{"workspace_id" => workspace.id})

      assert redirected_to(conn) == "/select-workspace"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "suspended"
    end

    test "rejects missing workspace_id param", %{conn: conn, user: user} do
      conn =
        conn
        |> log_in_user(user)
        |> post("/set-workspace", %{})

      assert redirected_to(conn) == "/select-workspace"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid workspace."
    end

    test "unauthenticated user is redirected to login", %{conn: conn, workspace: workspace} do
      conn = post(conn, "/set-workspace", %{"workspace_id" => workspace.id})

      assert redirected_to(conn) == "/users/log-in"
    end

    test "system owner can access workspace without membership", %{conn: conn} do
      system_owner = user_fixture()

      system_owner
      |> Ecto.Changeset.change(is_system_owner: true)
      |> Repo.update!()

      # Create a workspace the system owner is NOT a member of
      other_workspace = workspace_fixture(%{name: "System Owner Access"})

      conn =
        conn
        |> log_in_user(system_owner)
        |> post("/set-workspace", %{"workspace_id" => other_workspace.id})

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :current_workspace_id) == other_workspace.id
    end
  end
end
