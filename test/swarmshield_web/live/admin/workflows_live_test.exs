defmodule SwarmshieldWeb.Admin.WorkflowsLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures
  import Swarmshield.GhostProtocolFixtures

  # ---------------------------------------------------------------------------
  # Setup: user with admin:access + workflow permissions
  # ---------------------------------------------------------------------------

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "admin_role_#{System.unique_integer([:positive])}"})

    # Admin access permission (required by live_session :workspace_admin on_mount)
    admin_perm = permission_fixture(%{resource: "admin", action: "access"})
    role_permission_fixture(role, admin_perm)

    # Workflow CRUD permissions
    view_perm = permission_fixture(%{resource: "workflows", action: "view"})
    create_perm = permission_fixture(%{resource: "workflows", action: "create"})
    update_perm = permission_fixture(%{resource: "workflows", action: "update"})
    delete_perm = permission_fixture(%{resource: "workflows", action: "delete"})

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

  # ---------------------------------------------------------------------------
  # Helper: build a conn for a restricted user (reuses existing permissions)
  # ---------------------------------------------------------------------------

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
  # Index: mount and display
  # ---------------------------------------------------------------------------

  describe "index - mount and display" do
    test "renders workflows page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/workflows")

      assert html =~ "Workflows"
      assert html =~ "0 workflows configured"
      assert html =~ "No workflows configured"
      assert has_element?(view, "a", "New Workflow")
    end

    test "lists existing workflows", %{conn: conn, workspace: workspace} do
      _w1 = workflow_fixture(%{workspace_id: workspace.id, name: "Security Pipeline"})
      _w2 = workflow_fixture(%{workspace_id: workspace.id, name: "Content Filter"})

      {:ok, _view, html} = live(conn, ~p"/admin/workflows")

      assert html =~ "Security Pipeline"
      assert html =~ "Content Filter"
      assert html =~ "2 workflows"
      refute html =~ "No workflows configured"
    end

    test "displays workflow trigger badges", %{conn: conn, workspace: workspace} do
      _w1 = workflow_fixture(%{workspace_id: workspace.id, trigger_on: :flagged})
      _w2 = workflow_fixture(%{workspace_id: workspace.id, trigger_on: :blocked})
      _w3 = workflow_fixture(%{workspace_id: workspace.id, trigger_on: :manual})
      _w4 = workflow_fixture(%{workspace_id: workspace.id, trigger_on: :all})

      {:ok, _view, html} = live(conn, ~p"/admin/workflows")

      assert html =~ "Flagged"
      assert html =~ "Blocked"
      assert html =~ "Manual"
      assert html =~ "All"
    end

    test "displays enabled/disabled status badges", %{conn: conn, workspace: workspace} do
      _enabled = workflow_fixture(%{workspace_id: workspace.id, enabled: true})
      _disabled = workflow_fixture(%{workspace_id: workspace.id, enabled: false})

      {:ok, _view, html} = live(conn, ~p"/admin/workflows")

      assert html =~ "Enabled"
      assert html =~ "Disabled"
    end

    test "displays ghost protocol config badge", %{conn: conn, workspace: workspace} do
      gp_config =
        ghost_protocol_config_fixture(%{workspace_id: workspace.id, name: "Ephemeral-7d"})

      _workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: gp_config.id,
          name: "Ghost Workflow"
        })

      _standard = workflow_fixture(%{workspace_id: workspace.id, name: "Standard Workflow"})

      {:ok, _view, html} = live(conn, ~p"/admin/workflows")

      assert html =~ "Ephemeral-7d"
      assert html =~ "Standard"
    end

    test "displays step count for workflows", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})

      _step1 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          position: 1
        })

      _step2 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          position: 2
        })

      {:ok, _view, html} = live(conn, ~p"/admin/workflows")

      assert html =~ "2"
    end
  end

  # ---------------------------------------------------------------------------
  # Create workflow
  # ---------------------------------------------------------------------------

  describe "create workflow" do
    test "navigates to new workflow form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/workflows")

      view
      |> element("a", "New Workflow")
      |> render_click()

      assert_patch(view, ~p"/admin/workflows/new")
      assert render(view) =~ "New Workflow"
      assert render(view) =~ "Configure the deliberation pipeline"
    end

    test "creates workflow with valid data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/workflows/new")

      view
      |> form("#workflow-form", %{
        workflow: %{
          name: "My Security Pipeline",
          description: "Analyzes flagged events",
          trigger_on: "flagged",
          timeout_seconds: "600",
          max_retries: "3",
          enabled: "true"
        }
      })
      |> render_submit()

      assert_patch(view, "/admin/workflows")
      html = render(view)
      assert html =~ "Workflow created."
      assert html =~ "My Security Pipeline"
    end

    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/workflows/new")

      assert view
             |> form("#workflow-form", %{
               workflow: %{name: ""}
             })
             |> render_change() =~ "can&#39;t be blank"
    end

    test "creates workflow with ghost protocol config", %{conn: conn, workspace: workspace} do
      gp_config =
        ghost_protocol_config_fixture(%{workspace_id: workspace.id, name: "Ephemeral Config"})

      {:ok, view, html} = live(conn, ~p"/admin/workflows/new")

      # Config should appear in dropdown
      assert html =~ "Ephemeral Config"
      assert html =~ "None (Standard)"

      view
      |> form("#workflow-form", %{
        workflow: %{
          name: "Ghost Workflow",
          trigger_on: "flagged",
          ghost_protocol_config_id: gp_config.id
        }
      })
      |> render_submit()

      assert_patch(view, "/admin/workflows")
    end

    test "shows validation errors for invalid timeout", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/workflows/new")

      html =
        view
        |> form("#workflow-form", %{
          workflow: %{name: "Test", timeout_seconds: "5"}
        })
        |> render_change()

      assert html =~ "must be greater than or equal to 30"
    end
  end

  # ---------------------------------------------------------------------------
  # Edit workflow
  # ---------------------------------------------------------------------------

  describe "edit workflow" do
    test "navigates to edit form and displays current values", %{
      conn: conn,
      workspace: workspace
    } do
      workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          name: "Original Name",
          description: "Original desc",
          trigger_on: :blocked
        })

      {:ok, _view, html} = live(conn, ~p"/admin/workflows/#{workflow.id}/edit")

      assert html =~ "Edit Workflow"
      assert html =~ "Original Name"
      assert html =~ "Original desc"
    end

    test "updates workflow with valid changes", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id, name: "Old Name"})

      {:ok, view, _html} = live(conn, ~p"/admin/workflows/#{workflow.id}/edit")

      view
      |> form("#workflow-form", %{
        workflow: %{name: "Updated Name", description: "New description"}
      })
      |> render_submit()

      assert_patch(view, "/admin/workflows")
      html = render(view)
      assert html =~ "Workflow updated."
      assert html =~ "Updated Name"
    end

    test "prevents editing workflow from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_workflow = workflow_fixture(%{workspace_id: other_workspace.id})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/admin/workflows/#{other_workflow.id}/edit")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Toggle enabled
  # ---------------------------------------------------------------------------

  describe "toggle enabled" do
    test "toggles workflow enabled status", %{conn: conn, workspace: workspace} do
      workflow =
        workflow_fixture(%{workspace_id: workspace.id, enabled: true, name: "Toggle Me"})

      {:ok, view, _html} = live(conn, ~p"/admin/workflows")

      # Toggle from enabled -> disabled
      view |> render_click("toggle_enabled", %{"id" => workflow.id})

      html = render(view)
      assert html =~ "Disabled"
    end

    test "prevents toggling workflow from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()

      other_workflow =
        workflow_fixture(%{workspace_id: other_workspace.id, enabled: true, name: "Other WF"})

      {:ok, view, _html} = live(conn, ~p"/admin/workflows")

      # Try to toggle - should show error (workflow doesn't belong to our workspace)
      html = view |> render_click("toggle_enabled", %{"id" => other_workflow.id})
      assert html =~ "Workflow not found"
    end
  end

  # ---------------------------------------------------------------------------
  # Delete workflow
  # ---------------------------------------------------------------------------

  describe "delete workflow" do
    test "deletes a workflow", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id, name: "Delete Me"})

      {:ok, view, _html} = live(conn, ~p"/admin/workflows")

      assert render(view) =~ "Delete Me"

      view |> render_click("delete", %{"id" => workflow.id})

      html = render(view)
      assert html =~ "Workflow deleted"
      refute html =~ "Delete Me"
    end

    test "prevents deleting workflow from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_workflow = workflow_fixture(%{workspace_id: other_workspace.id})

      {:ok, view, _html} = live(conn, ~p"/admin/workflows")

      html = view |> render_click("delete", %{"id" => other_workflow.id})
      assert html =~ "Workflow not found"
    end
  end

  # ---------------------------------------------------------------------------
  # Security: permission checks
  # ---------------------------------------------------------------------------

  describe "security" do
    test "redirects when user lacks workflows:view permission", %{
      conn: conn,
      permissions: perms
    } do
      # User with admin:access but NO workflows:view
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin])

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/admin/workflows")
    end

    test "hides create button without workflows:create permission", %{
      conn: conn,
      permissions: perms
    } do
      # User with admin:access + workflows:view only
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, _view, html} = live(conn2, ~p"/admin/workflows")

      refute html =~ "New Workflow"
    end

    test "rejects create action without workflows:create permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, view, _html} = live(conn2, ~p"/admin/workflows/new")

      html =
        view
        |> form("#workflow-form", %{
          workflow: %{name: "Sneaky Create", trigger_on: "flagged"}
        })
        |> render_submit()

      assert html =~ "Unauthorized"
    end

    test "rejects delete action without workflows:delete permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      wf = workflow_fixture(%{workspace_id: workspace2.id})

      {:ok, view, _html} = live(conn2, ~p"/admin/workflows")

      html = view |> render_click("delete", %{"id" => wf.id})
      assert html =~ "Unauthorized"
    end

    test "scopes data to current workspace only", %{conn: conn, workspace: workspace} do
      _our_wf = workflow_fixture(%{workspace_id: workspace.id, name: "Our Workflow"})

      other_workspace = workspace_fixture()
      _other_wf = workflow_fixture(%{workspace_id: other_workspace.id, name: "Other Workflow"})

      {:ok, _view, html} = live(conn, ~p"/admin/workflows")

      assert html =~ "Our Workflow"
      refute html =~ "Other Workflow"
      assert html =~ "1 workflow configured"
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub: real-time updates from other admin users
  # ---------------------------------------------------------------------------

  describe "pubsub real-time updates" do
    test "receives workflow_created broadcast from another user", %{
      conn: conn,
      workspace: workspace
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/workflows")

      # Simulate broadcast from another user
      workflow = workflow_fixture(%{workspace_id: workspace.id, name: "Remote Workflow"})
      workflow = Swarmshield.Workflows.preload_workflow_assocs(workflow)

      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "workflows:#{workspace.id}",
        {:workflow_created, workflow}
      )

      html = render(view)
      assert html =~ "Remote Workflow"
    end

    test "receives workflow_deleted broadcast from another user", %{
      conn: conn,
      workspace: workspace
    } do
      workflow = workflow_fixture(%{workspace_id: workspace.id, name: "Soon Deleted"})

      {:ok, view, _html} = live(conn, ~p"/admin/workflows")
      assert render(view) =~ "Soon Deleted"

      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "workflows:#{workspace.id}",
        {:workflow_deleted, workflow}
      )

      html = render(view)
      refute html =~ "Soon Deleted"
    end
  end
end
