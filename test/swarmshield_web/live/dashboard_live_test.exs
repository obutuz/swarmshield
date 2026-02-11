defmodule SwarmshieldWeb.DashboardLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures
  alias Swarmshield.Accounts.Scope

  setup %{conn: conn} do
    # Create user, workspace, role with dashboard:view permission
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "analyst_#{System.unique_integer([:positive])}"})

    # Create dashboard:view permission and bind to role
    permission = permission_fixture(%{resource: "dashboard", action: "view"})
    role_permission_fixture(role, permission)

    # Assign user to workspace with role
    user_workspace_role_fixture(user, workspace, role)

    scope = Scope.for_user(user)
    token = Swarmshield.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:current_workspace_id, workspace.id)

    %{conn: conn, user: user, workspace: workspace, scope: scope}
  end

  describe "mount and render" do
    test "renders dashboard with loading state then stats", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/dashboard")

      # Initially should show the dashboard header
      assert html =~ "Security Operations"
      assert has_element?(view, "#dashboard-header")

      # Wait for async to complete
      _async_html = render_async(view)

      # Should show stat sections
      assert has_element?(view, "#event-stats-section")
      assert has_element?(view, "#delib-stats-section")
      assert has_element?(view, "#ghost-stats-section")
      assert has_element?(view, "#quick-actions")
    end

    test "shows zero counts for empty workspace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      html = render_async(view)

      # All stat cards should be present with zero values
      assert has_element?(view, "#stat-total-events")
      assert has_element?(view, "#stat-flagged-events")
      assert has_element?(view, "#stat-blocked-events")
      assert has_element?(view, "#stat-active-agents")
      assert has_element?(view, "#stat-active-deliberations")
      assert has_element?(view, "#stat-verdicts-today")
      assert has_element?(view, "#stat-active-ephemeral")
      assert has_element?(view, "#stat-sessions-wiped")
      assert has_element?(view, "#stat-active-configs")

      # Values should be "0"
      assert html =~ "0"
    end

    test "shows correct counts with data present", %{conn: conn, workspace: workspace} do
      # Create an active agent
      agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          status: :active
        })

      # Create events
      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        status: :allowed
      })

      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        status: :flagged
      })

      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        status: :blocked
      })

      {:ok, view, _html} = live(conn, ~p"/dashboard")
      html = render_async(view)

      # Should show non-zero values
      assert has_element?(view, "#stat-total-events")
      assert has_element?(view, "#stat-active-agents")

      # 3 events total, 1 flagged, 1 blocked, 1 active agent
      assert html =~ "3"
      assert html =~ "1"
    end
  end

  describe "GhostProtocol stats" do
    test "shows zero when no ephemeral sessions configured", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      render_async(view)

      assert has_element?(view, "#stat-active-ephemeral")
      assert has_element?(view, "#stat-sessions-wiped")
      assert has_element?(view, "#stat-active-configs")

      ghost_section =
        view
        |> element("#ghost-stats-grid")
        |> render()

      assert ghost_section =~ "0"
    end
  end

  describe "PubSub real-time updates" do
    test "increments event counter on PubSub event_created", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      _html = render_async(view)

      # Broadcast a new event
      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "events:#{workspace.id}",
        {:event_created, %{id: Ecto.UUID.generate(), status: :allowed}}
      )

      # Give time for the message to be processed
      html = render(view)

      # The total events should now show 1
      assert has_element?(view, "#stat-total-events")
      assert html =~ "1"
    end

    test "increments deliberation counter on session_created", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      _html = render_async(view)

      session_id = Ecto.UUID.generate()

      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "deliberations:#{workspace.id}",
        {:session_created, session_id, :pending}
      )

      html = render(view)

      assert has_element?(view, "#stat-active-deliberations")
      assert html =~ "1"
    end

    test "increments verdict counter and decrements active on session completed", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard")
      _html = render_async(view)

      session_id = Ecto.UUID.generate()

      # First create a session to increment active
      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "deliberations:#{workspace.id}",
        {:session_created, session_id, :pending}
      )

      render(view)

      # Then complete it
      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "deliberations:#{workspace.id}",
        {:session_updated, session_id, :completed}
      )

      html = render(view)

      # Should show 1 verdict and 0 active deliberations
      assert has_element?(view, "#stat-verdicts-today")
      assert has_element?(view, "#stat-active-deliberations")

      # Both verdict today = 1 and active deliberations = 0 are present
      assert html =~ "1"
    end
  end

  describe "permission check" do
    test "redirects when user lacks dashboard:view permission", %{conn: conn} do
      # Create a user without dashboard:view permission
      user2 = user_fixture()
      workspace2 = workspace_fixture()
      role2 = role_fixture(%{name: "noperm_#{System.unique_integer([:positive])}"})

      # No permissions assigned to this role
      user_workspace_role_fixture(user2, workspace2, role2)

      token2 = Swarmshield.Accounts.generate_user_session_token(user2)

      conn2 =
        conn
        |> recycle()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, token2)
        |> Plug.Conn.put_session(:current_workspace_id, workspace2.id)

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/dashboard")
    end
  end

  describe "responsive layout" do
    test "shows quick navigation links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      assert has_element?(view, "#quick-actions")

      html = render(view)
      assert html =~ "View Events"
      assert html =~ "Agent Registry"
      assert html =~ "Deliberations"
      assert html =~ "GhostProtocol"
    end
  end
end
