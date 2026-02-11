defmodule SwarmshieldWeb.DeliberationsLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures
  import Swarmshield.GhostProtocolFixtures

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "analyst_#{System.unique_integer([:positive])}"})

    permission = permission_fixture(%{resource: "deliberations", action: "view"})
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

  describe "mount and render" do
    test "renders deliberations page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/deliberations")

      assert html =~ "Deliberation Sessions"
      assert has_element?(view, "#deliberations-header")
      assert has_element?(view, "#sessions-empty")
      assert html =~ "No deliberation sessions"
    end

    test "renders sessions table with data", %{conn: conn, workspace: workspace} do
      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :completed,
          trigger: :automatic
        })

      verdict_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        decision: :block,
        confidence: 0.95,
        consensus_reached: true
      })

      {:ok, view, html} = live(conn, ~p"/deliberations")

      assert has_element?(view, "#sessions-table")
      refute has_element?(view, "#sessions-empty")
      assert html =~ "Completed"
      assert html =~ "Block"
      assert html =~ "95.0%"
    end
  end

  describe "filtering" do
    setup %{workspace: workspace} do
      completed_session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :completed,
          trigger: :automatic
        })

      _pending_session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :pending,
          trigger: :manual
        })

      %{completed_session: completed_session}
    end

    test "filters by status", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/deliberations?status=completed")

      # Should show 1 session (total count)
      assert html =~ "1</span> sessions"
    end

    test "filters by trigger", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/deliberations?trigger=manual")

      # Should show 1 session (the manual one)
      assert html =~ "1</span> sessions"
    end

    test "clear filters resets all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deliberations?status=completed")

      view |> element("button", "Clear all") |> render_click()

      html = render(view)
      # Both sessions should be visible after clearing
      assert html =~ "2</span> sessions"
    end
  end

  describe "verdict display" do
    test "shows verdict decision and confidence", %{conn: conn, workspace: workspace} do
      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :completed,
          trigger: :automatic
        })

      verdict_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        decision: :allow,
        confidence: 0.88,
        consensus_reached: true
      })

      {:ok, _view, html} = live(conn, ~p"/deliberations")

      assert html =~ "Allow"
      assert html =~ "88.0%"
    end

    test "shows dash when no verdict", %{conn: conn, workspace: workspace} do
      _session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :analyzing,
          trigger: :automatic
        })

      {:ok, _view, html} = live(conn, ~p"/deliberations")

      assert html =~ "Analyzing"
    end
  end

  describe "GhostProtocol ephemeral indicator" do
    test "shows Ephemeral badge for sessions with ghost_protocol_config", %{
      conn: conn,
      workspace: workspace
    } do
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
          status: :completed,
          trigger: :automatic
        })

      {:ok, _view, html} = live(conn, ~p"/deliberations")

      assert html =~ "Ephemeral"
    end
  end

  describe "permission check" do
    test "redirects when user lacks deliberations:view permission", %{conn: conn} do
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
               live(conn2, ~p"/deliberations")
    end
  end

  describe "filter bar UI" do
    test "shows filter bar with dropdowns", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deliberations")

      assert has_element?(view, "#filter-bar")
      assert has_element?(view, "select[name='status']")
      assert has_element?(view, "select[name='trigger']")
    end
  end
end
