defmodule SwarmshieldWeb.Admin.RegisteredAgentsLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "admin_role_#{System.unique_integer([:positive])}"})

    admin_perm = permission_fixture(%{resource: "admin", action: "access"})
    role_permission_fixture(role, admin_perm)

    view_perm = permission_fixture(%{resource: "agents", action: "view"})
    create_perm = permission_fixture(%{resource: "agents", action: "create"})
    update_perm = permission_fixture(%{resource: "agents", action: "update"})
    delete_perm = permission_fixture(%{resource: "agents", action: "delete"})

    role_permission_fixture(role, view_perm)
    role_permission_fixture(role, create_perm)
    role_permission_fixture(role, update_perm)
    role_permission_fixture(role, delete_perm)

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
        create: create_perm,
        update: update_perm,
        delete: delete_perm
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
  # Index
  # ---------------------------------------------------------------------------

  describe "index" do
    test "renders registered agents page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/registered-agents")

      assert html =~ "Registered Agents"
      assert html =~ "0 agent(s)"
      assert html =~ "No registered agents"
      assert has_element?(view, "a", "Register Agent")
    end

    test "lists existing agents with status badges", %{conn: conn, workspace: workspace} do
      _a1 =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "Alpha Agent"
        })

      _a2 =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "Beta Agent"
        })

      {:ok, _view, html} = live(conn, ~p"/admin/registered-agents")

      assert html =~ "Alpha Agent"
      assert html =~ "Beta Agent"
      assert html =~ "2 agent(s)"
    end

    test "shows API key prefix", %{conn: conn, workspace: workspace} do
      _agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "Key Agent"
        })

      {:ok, _view, html} = live(conn, ~p"/admin/registered-agents")

      # api_key_prefix is 8 chars set by fixture
      assert html =~ "..."
    end
  end

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  describe "create agent" do
    test "navigates to new agent form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/registered-agents")

      view |> element("a", "Register Agent") |> render_click()

      assert_patch(view, ~p"/admin/registered-agents/new")
      assert render(view) =~ "Register Agent"
    end

    test "creates agent and shows API key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/registered-agents/new")

      view
      |> form("#registered-agent-form", %{
        registered_agent: %{
          name: "New Test Agent",
          agent_type: "autonomous",
          description: "A test agent"
        }
      })
      |> render_submit()

      assert_patch(view, "/admin/registered-agents")
      html = render(view)
      assert html =~ "Agent registered"
      assert html =~ "copy it now"
    end

    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/registered-agents/new")

      assert view
             |> form("#registered-agent-form", %{registered_agent: %{name: ""}})
             |> render_change() =~ "can&#39;t be blank"
    end
  end

  # ---------------------------------------------------------------------------
  # Edit
  # ---------------------------------------------------------------------------

  describe "edit agent" do
    test "displays current values in edit form", %{conn: conn, workspace: workspace} do
      agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "Original Agent"
        })

      {:ok, _view, html} = live(conn, ~p"/admin/registered-agents/#{agent.id}/edit")

      assert html =~ "Edit Agent"
      assert html =~ "Original Agent"
    end

    test "updates agent with valid changes", %{conn: conn, workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "Old Agent"})

      {:ok, view, _html} = live(conn, ~p"/admin/registered-agents/#{agent.id}/edit")

      view
      |> form("#registered-agent-form", %{
        registered_agent: %{name: "Updated Agent"}
      })
      |> render_submit()

      assert_patch(view, "/admin/registered-agents")
      html = render(view)
      assert html =~ "Agent updated"
      assert html =~ "Updated Agent"
    end

    test "prevents editing agent from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_agent = registered_agent_fixture(%{workspace_id: other_workspace.id})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/admin/registered-agents/#{other_agent.id}/edit")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Delete
  # ---------------------------------------------------------------------------

  describe "delete agent" do
    test "deletes agent without recent events", %{conn: conn, workspace: workspace} do
      agent =
        registered_agent_fixture(%{workspace_id: workspace.id, name: "Delete Me"})

      {:ok, view, _html} = live(conn, ~p"/admin/registered-agents")

      assert render(view) =~ "Delete Me"

      view |> render_click("delete", %{"id" => agent.id})

      html = render(view)
      assert html =~ "Agent deleted"
      refute html =~ "Delete Me"
    end

    test "prevents deleting agent with recent events", %{conn: conn, workspace: workspace} do
      agent =
        registered_agent_fixture(%{workspace_id: workspace.id, name: "Active Agent"})

      # Create a recent event for this agent
      _event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id
        })

      {:ok, view, _html} = live(conn, ~p"/admin/registered-agents")

      view |> render_click("delete", %{"id" => agent.id})

      html = render(view)
      assert html =~ "Cannot delete"
      assert html =~ "Active Agent"
    end
  end

  # ---------------------------------------------------------------------------
  # Status toggle
  # ---------------------------------------------------------------------------

  describe "status toggle" do
    test "suspends an active agent", %{conn: conn, workspace: workspace} do
      agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "Toggle Agent",
          status: :active
        })

      {:ok, view, _html} = live(conn, ~p"/admin/registered-agents")

      view |> render_click("toggle_status", %{"id" => agent.id})

      html = render(view)
      assert html =~ "suspended"
    end
  end

  # ---------------------------------------------------------------------------
  # API Key regeneration
  # ---------------------------------------------------------------------------

  describe "api key regeneration" do
    test "regenerates key and shows it once", %{conn: conn, workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "Key Agent"})

      {:ok, view, _html} = live(conn, ~p"/admin/registered-agents")

      view |> render_click("regenerate_key", %{"id" => agent.id})

      html = render(view)
      assert html =~ "API key regenerated"
      assert html =~ "copy it now"
    end

    test "dismisses key display", %{conn: conn, workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, view, _html} = live(conn, ~p"/admin/registered-agents")

      view |> render_click("regenerate_key", %{"id" => agent.id})
      assert render(view) =~ "copy it now"

      view |> render_click("dismiss_key")
      refute render(view) =~ "copy it now"
    end
  end

  # ---------------------------------------------------------------------------
  # Security
  # ---------------------------------------------------------------------------

  describe "security" do
    test "redirects when user lacks agents:view permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin])

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/admin/registered-agents")
    end

    test "rejects create without agents:create permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, view, _html} = live(conn2, ~p"/admin/registered-agents/new")

      html =
        view
        |> form("#registered-agent-form", %{
          registered_agent: %{name: "Sneaky Agent", agent_type: "autonomous"}
        })
        |> render_submit()

      assert html =~ "Unauthorized"
    end

    test "scopes data to current workspace only", %{conn: conn, workspace: workspace} do
      _ours =
        registered_agent_fixture(%{workspace_id: workspace.id, name: "Our Agent"})

      other_workspace = workspace_fixture()

      _other =
        registered_agent_fixture(%{workspace_id: other_workspace.id, name: "Other Agent"})

      {:ok, _view, html} = live(conn, ~p"/admin/registered-agents")

      assert html =~ "Our Agent"
      refute html =~ "Other Agent"
    end
  end
end
