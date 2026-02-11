defmodule SwarmshieldWeb.EventsLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "analyst_#{System.unique_integer([:positive])}"})

    # Create events:view permission and bind to role
    permission = permission_fixture(%{resource: "events", action: "view"})
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
    test "renders events page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/events")

      assert html =~ "Event Stream"
      assert has_element?(view, "#events-header")
      assert has_element?(view, "#events-empty")
      assert html =~ "No events yet"
    end

    test "renders events table with data", %{conn: conn, workspace: workspace} do
      agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          status: :active
        })

      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        content: "Agent performed action alpha",
        event_type: :action,
        status: :allowed
      })

      {:ok, view, html} = live(conn, ~p"/events")

      assert html =~ "Agent performed action alpha"
      assert has_element?(view, "#events-table")
      refute has_element?(view, "#events-empty")
    end
  end

  describe "filtering" do
    setup %{workspace: workspace} do
      agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          status: :active
        })

      allowed_event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Allowed action content",
          event_type: :action,
          status: :allowed
        })

      flagged_event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Flagged output content",
          event_type: :output,
          status: :flagged
        })

      blocked_event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Blocked tool call content",
          event_type: :tool_call,
          status: :blocked
        })

      %{
        agent: agent,
        allowed_event: allowed_event,
        flagged_event: flagged_event,
        blocked_event: blocked_event
      }
    end

    test "filters by status", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/events?status=flagged")

      html = render(view)
      assert html =~ "Flagged output content"
      refute html =~ "Allowed action content"
      refute html =~ "Blocked tool call content"
    end

    test "filters by event type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/events?event_type=tool_call")

      html = render(view)
      assert html =~ "Blocked tool call content"
      refute html =~ "Allowed action content"
    end

    test "filters by agent", %{conn: conn, agent: agent} do
      {:ok, view, _html} = live(conn, ~p"/events?agent=#{agent.id}")

      html = render(view)
      # All 3 events belong to this agent, so all should appear
      assert html =~ "Allowed action content"
      assert html =~ "Flagged output content"
      assert html =~ "Blocked tool call content"
    end

    test "combined filters work correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/events?status=allowed&event_type=action")

      html = render(view)
      assert html =~ "Allowed action content"
      refute html =~ "Flagged output content"
      refute html =~ "Blocked tool call content"
    end

    test "search filters by content text", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/events?search=Flagged")

      html = render(view)
      assert html =~ "Flagged output content"
      refute html =~ "Allowed action content"
    end

    test "clear filters resets all", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/events?status=flagged")

      html = render(view)
      refute html =~ "Allowed action content"

      view |> element("button", "Clear all") |> render_click()

      html = render(view)
      assert html =~ "Allowed action content"
      assert html =~ "Flagged output content"
      assert html =~ "Blocked tool call content"
    end
  end

  describe "PubSub real-time updates" do
    test "prepends new event via PubSub broadcast", %{conn: conn, workspace: workspace} do
      agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          status: :active
        })

      {:ok, view, _html} = live(conn, ~p"/events")

      # Create an event and broadcast it
      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Real-time event arrived",
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
      assert html =~ "Real-time event arrived"
    end
  end

  describe "permission check" do
    test "redirects when user lacks events:view permission", %{conn: conn} do
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
               live(conn2, ~p"/events")
    end
  end

  describe "pagination" do
    test "shows load more button when more events exist", %{conn: conn, workspace: workspace} do
      agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          status: :active
        })

      # Create 51 events to trigger pagination (page_size = 50)
      for i <- 1..51 do
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Event number #{i}",
          event_type: :action,
          status: :allowed
        })
      end

      {:ok, view, _html} = live(conn, ~p"/events")

      assert has_element?(view, "button", "Load more events")
    end

    test "does not show load more when all events fit on one page", %{
      conn: conn,
      workspace: workspace
    } do
      agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          status: :active
        })

      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        content: "Single event",
        event_type: :action,
        status: :allowed
      })

      {:ok, view, _html} = live(conn, ~p"/events")

      refute has_element?(view, "button", "Load more events")
    end
  end

  describe "filter bar UI" do
    test "shows filter bar with dropdowns", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/events")

      assert has_element?(view, "#filter-bar")
      assert has_element?(view, "select[name='status']")
      assert has_element?(view, "select[name='event_type']")
      assert has_element?(view, "select[name='agent']")
      assert has_element?(view, "input[name='search']")
    end
  end
end
