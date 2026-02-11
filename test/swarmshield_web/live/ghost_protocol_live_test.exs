defmodule SwarmshieldWeb.GhostProtocolLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures
  import Swarmshield.GhostProtocolFixtures

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "gp_role_#{System.unique_integer([:positive])}"})

    permission = permission_fixture(%{resource: "ghost_protocol", action: "view"})
    role_permission_fixture(role, permission)

    user_workspace_role_fixture(user, workspace, role)

    token = Swarmshield.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:current_workspace_id, workspace.id)

    %{conn: conn, user: user, workspace: workspace}
  end

  describe "mount and display" do
    test "renders GhostProtocol page with empty states", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/ghost-protocol")

      assert html =~ "GhostProtocol"
      assert has_element?(view, "#gp-header")
      assert has_element?(view, "#gp-stats")
      assert has_element?(view, "#active-sessions-section")
      assert has_element?(view, "#wipe-history-section")
      assert html =~ "No active ghost sessions"
      assert html =~ "No wipe history"
    end

    test "renders stats cards with zero values", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/ghost-protocol")

      assert html =~ "Active Sessions"
      assert html =~ "Sessions Wiped"
      assert html =~ "Active Configs"
    end
  end

  describe "active sessions" do
    test "shows active ephemeral session", %{conn: conn, workspace: workspace} do
      gp_config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: gp_config.id
        })

      _session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :analyzing,
          trigger: :automatic
        })

      {:ok, view, html} = live(conn, ~p"/ghost-protocol")

      assert has_element?(view, "#active-sessions-stream")
      assert html =~ "Analyzing"
      assert html =~ "immediate"
    end

    test "does not show non-ephemeral sessions as active", %{
      conn: conn,
      workspace: workspace
    } do
      _session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :analyzing,
          trigger: :automatic
        })

      {:ok, _view, html} = live(conn, ~p"/ghost-protocol")

      assert html =~ "No active ghost sessions"
    end
  end

  describe "wipe history" do
    test "shows completed ephemeral sessions in history", %{
      conn: conn,
      workspace: workspace
    } do
      gp_config =
        ghost_protocol_config_fixture(%{workspace_id: workspace.id, crypto_shred: true})

      workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: gp_config.id
        })

      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :pending,
          trigger: :automatic
        })

      # Transition through to completed
      {:ok, s2} =
        Swarmshield.Deliberation.update_analysis_session(session, %{status: :analyzing})

      {:ok, s3} =
        Swarmshield.Deliberation.update_analysis_session(s2, %{status: :deliberating})

      {:ok, s4} =
        Swarmshield.Deliberation.update_analysis_session(s3, %{status: :voting})

      {:ok, _completed} =
        Swarmshield.Deliberation.update_analysis_session(s4, %{status: :completed})

      {:ok, view, html} = live(conn, ~p"/ghost-protocol")

      assert has_element?(view, "#history-stream")
      assert html =~ "Wiped"
      assert html =~ "Shred"
      assert html =~ "immediate"
    end
  end

  describe "stats" do
    test "shows correct stats with active config", %{conn: conn, workspace: workspace} do
      _gp_config = ghost_protocol_config_fixture(%{workspace_id: workspace.id, enabled: true})

      {:ok, _view, html} = live(conn, ~p"/ghost-protocol")

      # At least one active config
      assert html =~ "Active Configs"
    end
  end

  describe "security" do
    test "redirects when user lacks ghost_protocol:view permission", %{conn: conn} do
      user2 = user_fixture()
      workspace2 = workspace_fixture()
      role2 = role_fixture(%{name: "noperm_#{System.unique_integer([:positive])}"})

      user_workspace_role_fixture(user2, workspace2, role2)

      token2 = Swarmshield.Accounts.generate_user_session_token(user2)

      conn2 =
        conn
        |> recycle()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, token2)
        |> Plug.Conn.put_session(:current_workspace_id, workspace2.id)

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/ghost-protocol")
    end

    test "scopes data to current workspace only", %{conn: conn, workspace: workspace} do
      other_workspace = workspace_fixture()
      other_gp = ghost_protocol_config_fixture(%{workspace_id: other_workspace.id})

      other_workflow =
        workflow_fixture(%{
          workspace_id: other_workspace.id,
          ghost_protocol_config_id: other_gp.id
        })

      _other_session =
        analysis_session_fixture(%{
          workspace_id: other_workspace.id,
          workflow_id: other_workflow.id,
          status: :analyzing,
          trigger: :automatic
        })

      # Our workspace has no ephemeral sessions
      _our_gp = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      {:ok, _view, html} = live(conn, ~p"/ghost-protocol")

      # Should not see other workspace's active sessions
      assert html =~ "No active ghost sessions"
    end
  end
end
