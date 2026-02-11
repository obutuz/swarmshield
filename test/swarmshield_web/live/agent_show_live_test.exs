defmodule SwarmshieldWeb.AgentShowLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.PoliciesFixtures

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

    agent =
      registered_agent_fixture(%{
        workspace_id: workspace.id,
        name: "SentinelBot Alpha",
        description: "Primary security analysis agent",
        status: :active,
        agent_type: :autonomous,
        risk_level: :high,
        metadata: %{"model" => "gpt-4", "version" => "2.1"}
      })

    %{conn: conn, user: user, workspace: workspace, agent: agent}
  end

  describe "mount and display" do
    test "renders agent detail page", %{conn: conn, agent: agent} do
      {:ok, view, html} = live(conn, ~p"/agents/#{agent.id}")

      assert html =~ "SentinelBot Alpha"
      assert html =~ "Primary security analysis agent"
      assert has_element?(view, "#agent-header")
      assert has_element?(view, "#agent-info")
      assert has_element?(view, "#agent-stats")
    end

    test "shows agent type, API key prefix, and status badges", %{conn: conn, agent: agent} do
      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}")

      assert html =~ "Autonomous"
      assert html =~ agent.api_key_prefix
      assert html =~ "Active"
      assert html =~ "HIGH"
    end

    test "shows metadata when present", %{conn: conn, agent: agent} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      assert has_element?(view, "#agent-metadata")
      html = render(view)
      assert html =~ "gpt-4"
      assert html =~ "2.1"
    end

    test "shows stats with correct counts", %{conn: conn, workspace: workspace, agent: agent} do
      # Create events with different statuses
      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        content: "Allowed event",
        status: :allowed
      })

      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        content: "Flagged event",
        status: :flagged
      })

      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        content: "Blocked event",
        status: :blocked
      })

      {:ok, _view, html} = live(conn, ~p"/agents/#{agent.id}")

      # Total events = 3, Flagged = 1, Blocked = 1
      assert html =~ "Total Events"
      assert html =~ "Flagged"
      assert html =~ "Blocked"
    end
  end

  describe "events tab" do
    test "shows recent events for this agent", %{
      conn: conn,
      workspace: workspace,
      agent: agent
    } do
      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        content: "Agent performed file_read",
        event_type: :action,
        status: :allowed
      })

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      assert has_element?(view, "#events-tab")
      html = render(view)
      assert html =~ "Agent performed file_read"
    end

    test "shows empty state when no events", %{conn: conn, agent: agent} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      assert has_element?(view, "#events-empty")
      html = render(view)
      assert html =~ "No events recorded"
    end
  end

  describe "tab switching" do
    test "switches between events and violations tabs", %{conn: conn, agent: agent} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      # Events tab visible by default
      assert has_element?(view, "#events-tab")
      refute has_element?(view, "#violations-tab")

      # Switch to violations tab
      view |> element("button", "Violations") |> render_click()

      assert has_element?(view, "#violations-tab")
      refute has_element?(view, "#events-tab")

      # Switch back to events tab
      view |> element("button", "Recent Events") |> render_click()

      assert has_element?(view, "#events-tab")
      refute has_element?(view, "#violations-tab")
    end

    test "violations tab shows violations for this agent", %{
      conn: conn,
      workspace: workspace,
      agent: agent
    } do
      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Violated policy",
          status: :blocked
        })

      policy_violation_fixture(%{
        workspace_id: workspace.id,
        agent_event_id: event.id,
        action_taken: :blocked,
        severity: :high
      })

      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      view |> element("button", "Violations") |> render_click()

      html = render(view)
      assert html =~ "Blocked"
      refute has_element?(view, "#violations-empty")
    end

    test "violations tab shows empty state when no violations", %{conn: conn, agent: agent} do
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      view |> element("button", "Violations") |> render_click()

      assert has_element?(view, "#violations-empty")
      html = render(view)
      assert html =~ "No policy violations"
    end
  end

  describe "PubSub real-time updates" do
    test "prepends new event via PubSub broadcast", %{
      conn: conn,
      workspace: workspace,
      agent: agent
    } do
      {:ok, view, _html} = live(conn, ~p"/agents/#{agent.id}")

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Real-time event for this agent",
          event_type: :action,
          status: :allowed
        })

      event = Swarmshield.Repo.preload(event, :registered_agent)

      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "events:#{workspace.id}",
        {:event_created, event}
      )

      html = render(view)
      assert html =~ "Real-time event for this agent"
    end
  end

  describe "security" do
    test "redirects when agent not found", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: "/agents"}}} =
               live(conn, ~p"/agents/#{fake_id}")
    end

    test "redirects for agent from wrong workspace", %{conn: conn} do
      other_workspace = workspace_fixture()

      other_agent =
        registered_agent_fixture(%{
          workspace_id: other_workspace.id,
          name: "Other Agent",
          status: :active
        })

      assert {:error, {:redirect, %{to: "/agents"}}} =
               live(conn, ~p"/agents/#{other_agent.id}")
    end

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

      fake_id = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/agents/#{fake_id}")
    end
  end
end
