defmodule SwarmshieldWeb.AgentsLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "analyst_#{System.unique_integer([:positive])}"})

    permission = permission_fixture(%{resource: "agents", action: "view"})
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
    test "renders agents page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/agents")

      assert html =~ "Agent Registry"
      assert has_element?(view, "#agents-header")
      assert has_element?(view, "#agents-empty")
      assert html =~ "No agents registered"
    end

    test "renders agents table with data", %{conn: conn, workspace: workspace} do
      agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "SentinelBot Alpha",
          status: :active,
          agent_type: :autonomous,
          risk_level: :high
        })

      {:ok, view, html} = live(conn, ~p"/agents")

      assert html =~ "SentinelBot Alpha"
      assert html =~ agent.api_key_prefix
      assert has_element?(view, "#agents-table")
      refute has_element?(view, "#agents-empty")
    end
  end

  describe "filtering" do
    setup %{workspace: workspace} do
      active_agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "Active Autonomous Agent",
          status: :active,
          agent_type: :autonomous,
          risk_level: :high
        })

      suspended_agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "Suspended Chatbot Agent",
          status: :suspended,
          agent_type: :chatbot,
          risk_level: :low
        })

      revoked_agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "Revoked Tool Agent",
          status: :revoked,
          agent_type: :tool_agent,
          risk_level: :critical
        })

      %{
        active_agent: active_agent,
        suspended_agent: suspended_agent,
        revoked_agent: revoked_agent
      }
    end

    test "filters by status", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents?status=active")

      html = render(view)
      assert html =~ "Active Autonomous Agent"
      refute html =~ "Suspended Chatbot Agent"
      refute html =~ "Revoked Tool Agent"
    end

    test "filters by agent type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents?agent_type=chatbot")

      html = render(view)
      assert html =~ "Suspended Chatbot Agent"
      refute html =~ "Active Autonomous Agent"
      refute html =~ "Revoked Tool Agent"
    end

    test "search filters by name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents?search=Revoked")

      html = render(view)
      assert html =~ "Revoked Tool Agent"
      refute html =~ "Active Autonomous Agent"
      refute html =~ "Suspended Chatbot Agent"
    end

    test "combined filters work correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents?status=active&agent_type=autonomous")

      html = render(view)
      assert html =~ "Active Autonomous Agent"
      refute html =~ "Suspended Chatbot Agent"
      refute html =~ "Revoked Tool Agent"
    end

    test "clear filters resets all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents?status=suspended")

      html = render(view)
      refute html =~ "Active Autonomous Agent"

      view |> element("button", "Clear all") |> render_click()

      html = render(view)
      assert html =~ "Active Autonomous Agent"
      assert html =~ "Suspended Chatbot Agent"
      assert html =~ "Revoked Tool Agent"
    end
  end

  describe "permission check" do
    test "redirects when user lacks agents:view permission", %{conn: conn} do
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
               live(conn2, ~p"/agents")
    end
  end

  describe "badges and display" do
    test "renders correct status badges", %{conn: conn, workspace: workspace} do
      registered_agent_fixture(%{
        workspace_id: workspace.id,
        name: "Badge Test Agent",
        status: :active
      })

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "Active"
    end

    test "renders risk level badges", %{conn: conn, workspace: workspace} do
      registered_agent_fixture(%{
        workspace_id: workspace.id,
        name: "Critical Risk Agent",
        status: :active,
        risk_level: :critical
      })

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "CRITICAL"
    end

    test "shows agent count in header", %{conn: conn, workspace: workspace} do
      for i <- 1..3 do
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "Agent #{i}",
          status: :active
        })
      end

      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "3"
      assert html =~ "registered agents"
    end
  end

  describe "filter bar UI" do
    test "shows filter bar with dropdowns", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents")

      assert has_element?(view, "#filter-bar")
      assert has_element?(view, "select[name='status']")
      assert has_element?(view, "select[name='agent_type']")
      assert has_element?(view, "input[name='search']")
    end
  end
end
