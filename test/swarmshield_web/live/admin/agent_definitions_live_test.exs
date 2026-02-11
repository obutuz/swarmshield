defmodule SwarmshieldWeb.Admin.AgentDefinitionsLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures

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

  describe "index - mount and display" do
    test "renders agent definitions page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/agent-definitions")

      assert html =~ "Agent Definitions"
      assert html =~ "0 definitions configured"
      assert html =~ "No agent definitions configured"
      assert has_element?(view, "a", "New Definition")
    end

    test "lists existing definitions with model badges", %{conn: conn, workspace: workspace} do
      _d1 =
        agent_definition_fixture(%{
          workspace_id: workspace.id,
          name: "Security Analyst",
          role: "security_analyst",
          model: "claude-opus-4-6"
        })

      _d2 =
        agent_definition_fixture(%{
          workspace_id: workspace.id,
          name: "Ethics Reviewer",
          role: "ethics_reviewer",
          model: "claude-sonnet-4-5-20250929"
        })

      {:ok, _view, html} = live(conn, ~p"/admin/agent-definitions")

      assert html =~ "Security Analyst"
      assert html =~ "Ethics Reviewer"
      assert html =~ "2 definitions"
      assert html =~ "Opus 4.6"
      assert html =~ "Sonnet 4.5"
    end

    test "shows disabled definitions with muted styling", %{conn: conn, workspace: workspace} do
      _disabled =
        agent_definition_fixture(%{
          workspace_id: workspace.id,
          name: "Disabled Agent",
          enabled: false
        })

      {:ok, _view, html} = live(conn, ~p"/admin/agent-definitions")

      assert html =~ "Disabled Agent"
      assert html =~ "Disabled"
    end
  end

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  describe "create definition" do
    test "navigates to new definition form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/agent-definitions")

      view |> element("a", "New Definition") |> render_click()

      assert_patch(view, ~p"/admin/agent-definitions/new")
      assert render(view) =~ "New Agent Definition"
    end

    test "creates definition with valid data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/agent-definitions/new")

      # Set expertise via blur event
      view |> render_click("update_expertise", %{"value" => "threat detection, data privacy"})

      view
      |> form("#agent-definition-form", %{
        agent_definition: %{
          name: "My New Agent",
          role: "analyst",
          system_prompt: "You are an analyst.",
          model: "claude-opus-4-6",
          temperature: "0.5",
          max_tokens: "8192",
          enabled: "true"
        }
      })
      |> render_submit()

      assert_patch(view, "/admin/agent-definitions")
      html = render(view)
      assert html =~ "Agent definition created."
      assert html =~ "My New Agent"
    end

    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/agent-definitions/new")

      assert view
             |> form("#agent-definition-form", %{agent_definition: %{name: ""}})
             |> render_change() =~ "can&#39;t be blank"
    end

    test "shows character count for system prompt", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/agent-definitions/new")

      html =
        view
        |> form("#agent-definition-form", %{
          agent_definition: %{system_prompt: "Hello world prompt"}
        })
        |> render_change()

      assert html =~ "18 / 102,400 characters"
    end
  end

  # ---------------------------------------------------------------------------
  # Edit
  # ---------------------------------------------------------------------------

  describe "edit definition" do
    test "displays current values in edit form", %{conn: conn, workspace: workspace} do
      defn =
        agent_definition_fixture(%{
          workspace_id: workspace.id,
          name: "Original Agent",
          role: "original_role",
          system_prompt: "Original prompt content"
        })

      {:ok, _view, html} = live(conn, ~p"/admin/agent-definitions/#{defn.id}/edit")

      assert html =~ "Edit Agent Definition"
      assert html =~ "Original Agent"
      assert html =~ "original_role"
      assert html =~ "Original prompt content"
    end

    test "updates definition with valid changes", %{conn: conn, workspace: workspace} do
      defn = agent_definition_fixture(%{workspace_id: workspace.id, name: "Old Agent"})

      {:ok, view, _html} = live(conn, ~p"/admin/agent-definitions/#{defn.id}/edit")

      view
      |> form("#agent-definition-form", %{
        agent_definition: %{name: "Updated Agent"}
      })
      |> render_submit()

      assert_patch(view, "/admin/agent-definitions")
      html = render(view)
      assert html =~ "Agent definition updated."
      assert html =~ "Updated Agent"
    end

    test "prevents editing definition from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_defn = agent_definition_fixture(%{workspace_id: other_workspace.id})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/admin/agent-definitions/#{other_defn.id}/edit")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Delete
  # ---------------------------------------------------------------------------

  describe "delete definition" do
    test "deletes a definition", %{conn: conn, workspace: workspace} do
      defn = agent_definition_fixture(%{workspace_id: workspace.id, name: "Delete Me"})

      {:ok, view, _html} = live(conn, ~p"/admin/agent-definitions")

      assert render(view) =~ "Delete Me"

      view |> render_click("delete", %{"id" => defn.id})

      html = render(view)
      assert html =~ "Agent definition deleted."
      refute html =~ "Delete Me"
    end

    test "prevents deleting definition used in workflow steps", %{
      conn: conn,
      workspace: workspace
    } do
      defn = agent_definition_fixture(%{workspace_id: workspace.id, name: "In Use"})
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      workflow_step_fixture(%{workflow_id: workflow.id, agent_definition_id: defn.id})

      {:ok, view, _html} = live(conn, ~p"/admin/agent-definitions")

      view |> render_click("delete", %{"id" => defn.id})

      html = render(view)
      assert html =~ "Cannot delete"
      assert html =~ "In Use"
    end
  end

  # ---------------------------------------------------------------------------
  # Toggle
  # ---------------------------------------------------------------------------

  describe "toggle enabled" do
    test "toggles definition enabled status", %{conn: conn, workspace: workspace} do
      defn =
        agent_definition_fixture(%{workspace_id: workspace.id, name: "Toggle Me", enabled: true})

      {:ok, view, _html} = live(conn, ~p"/admin/agent-definitions")

      assert render(view) =~ "Enabled"

      view |> render_click("toggle_enabled", %{"id" => defn.id})

      assert render(view) =~ "Disabled"
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
               live(conn2, ~p"/admin/agent-definitions")
    end

    test "rejects create action without agents:create permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, view, _html} = live(conn2, ~p"/admin/agent-definitions/new")

      html =
        view
        |> form("#agent-definition-form", %{
          agent_definition: %{
            name: "Sneaky Agent",
            role: "sneaky",
            system_prompt: "test"
          }
        })
        |> render_submit()

      assert html =~ "Unauthorized"
    end

    test "rejects delete without agents:delete permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, workspace2} = restricted_conn(conn, [perms.admin, perms.view])
      defn = agent_definition_fixture(%{workspace_id: workspace2.id, name: "Protected"})

      {:ok, view, _html} = live(conn2, ~p"/admin/agent-definitions")

      view |> render_click("delete", %{"id" => defn.id})

      assert render(view) =~ "Unauthorized"
    end

    test "scopes data to current workspace only", %{conn: conn, workspace: workspace} do
      _our = agent_definition_fixture(%{workspace_id: workspace.id, name: "Our Agent"})

      other_workspace = workspace_fixture()
      _other = agent_definition_fixture(%{workspace_id: other_workspace.id, name: "Other Agent"})

      {:ok, _view, html} = live(conn, ~p"/admin/agent-definitions")

      assert html =~ "Our Agent"
      refute html =~ "Other Agent"
    end
  end
end
