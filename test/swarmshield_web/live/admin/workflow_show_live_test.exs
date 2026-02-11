defmodule SwarmshieldWeb.Admin.WorkflowShowLiveTest do
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

    admin_perm = permission_fixture(%{resource: "admin", action: "access"})
    role_permission_fixture(role, admin_perm)

    view_perm = permission_fixture(%{resource: "workflows", action: "view"})
    update_perm = permission_fixture(%{resource: "workflows", action: "update"})

    role_permission_fixture(role, view_perm)
    role_permission_fixture(role, update_perm)

    user_workspace_role_fixture(user, workspace, role)

    token = Swarmshield.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:current_workspace_id, workspace.id)

    workflow = workflow_fixture(%{workspace_id: workspace.id, name: "Test Pipeline"})

    %{
      conn: conn,
      user: user,
      workspace: workspace,
      workflow: workflow,
      permissions: %{admin: admin_perm, view: view_perm, update: update_perm}
    }
  end

  # ---------------------------------------------------------------------------
  # Helper: build a conn for a restricted user
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
  # Show: mount and display
  # ---------------------------------------------------------------------------

  describe "show - mount and display" do
    test "renders workflow details", %{conn: conn, workflow: workflow} do
      {:ok, _view, html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      assert html =~ "Test Pipeline"
      assert html =~ "Workflow Configuration"
      assert html =~ "Pipeline Steps"
      assert html =~ "0 steps"
      assert html =~ "No pipeline steps configured"
    end

    test "displays workflow configuration fields", %{conn: conn, workspace: workspace} do
      workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          name: "Config Display Test",
          trigger_on: :blocked,
          timeout_seconds: 600,
          max_retries: 5
        })

      {:ok, _view, html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      assert html =~ "Config Display Test"
      assert html =~ "Blocked"
      assert html =~ "600s"
      assert html =~ "5"
    end

    test "displays existing steps", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id, name: "Security Bot"})

      _step1 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          name: "Initial Analysis",
          position: 1
        })

      _step2 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          name: "Deep Scan",
          position: 2
        })

      {:ok, _view, html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      assert html =~ "Initial Analysis"
      assert html =~ "Deep Scan"
      assert html =~ "Security Bot"
      assert html =~ "2 steps"
      refute html =~ "No pipeline steps configured"
    end

    test "returns 404 for non-existent workflow", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/admin/workflows/#{Ecto.UUID.generate()}")
      end
    end

    test "returns 404 for workflow from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_workflow = workflow_fixture(%{workspace_id: other_workspace.id})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/admin/workflows/#{other_workflow.id}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GhostProtocol config display
  # ---------------------------------------------------------------------------

  describe "ghost protocol config display" do
    test "shows standard mode when no config linked", %{conn: conn, workflow: workflow} do
      {:ok, _view, html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      assert html =~ "Standard (non-ephemeral)"
    end

    test "shows ghost protocol panel when config linked", %{
      conn: conn,
      workspace: workspace
    } do
      gp_config =
        ghost_protocol_config_fixture(%{
          workspace_id: workspace.id,
          name: "Ephemeral-7d",
          wipe_strategy: :immediate,
          crypto_shred: true,
          max_session_duration_seconds: 300
        })

      workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: gp_config.id,
          name: "Ephemeral Workflow"
        })

      {:ok, _view, html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      assert html =~ "GhostProtocol: Ephemeral-7d"
      assert html =~ "immediate"
      assert html =~ "300s"
      assert html =~ "Ephemeral"
      refute html =~ "Standard (non-ephemeral)"
    end
  end

  # ---------------------------------------------------------------------------
  # Add step
  # ---------------------------------------------------------------------------

  describe "add step" do
    test "adds a step with valid data", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id, name: "Analyzer Agent"})

      {:ok, view, _html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      view
      |> form("#step-form", %{
        workflow_step: %{
          name: "First Analysis",
          agent_definition_id: agent_def.id,
          execution_mode: "sequential",
          timeout_seconds: "120"
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Step added."
      assert html =~ "First Analysis"
      assert html =~ "Analyzer Agent"
      assert html =~ "1 step"
    end

    test "auto-sets position to max + 1", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id, name: "Bot"})

      _step1 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          position: 1
        })

      {:ok, view, _html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      view
      |> form("#step-form", %{
        workflow_step: %{
          name: "Second Step",
          agent_definition_id: agent_def.id,
          execution_mode: "sequential",
          timeout_seconds: "120"
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Step added."
      assert html =~ "Second Step"
      assert html =~ "2 steps"
    end

    test "validates step form on change", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})

      {:ok, view, _html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      html =
        view
        |> form("#step-form", %{
          workflow_step: %{name: ""}
        })
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "adds step with optional prompt template", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})
      template = prompt_template_fixture(%{workspace_id: workspace.id, name: "Analysis Template"})

      {:ok, view, html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      # Template should appear in dropdown
      assert html =~ "Analysis Template"
      assert html =~ "None (use agent default)"

      view
      |> form("#step-form", %{
        workflow_step: %{
          name: "Templated Step",
          agent_definition_id: agent_def.id,
          prompt_template_id: template.id,
          execution_mode: "parallel",
          timeout_seconds: "180"
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Step added."
      assert html =~ "Templated Step"
      assert html =~ "Analysis Template"
    end

    test "rejects agent definition from another workspace", %{
      conn: conn,
      workspace: workspace
    } do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      other_workspace = workspace_fixture()
      other_agent = agent_definition_fixture(%{workspace_id: other_workspace.id})

      {:ok, view, _html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      # Bypass form helper select validation (simulates crafted request)
      html =
        view
        |> render_click("add_step", %{
          "workflow_step" => %{
            "name" => "Sneaky Step",
            "agent_definition_id" => other_agent.id,
            "execution_mode" => "sequential",
            "timeout_seconds" => "120"
          }
        })

      assert html =~ "Invalid agent definition"
    end
  end

  # ---------------------------------------------------------------------------
  # Delete step
  # ---------------------------------------------------------------------------

  describe "delete step" do
    test "removes a step", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      step =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          name: "Delete Me",
          position: 1
        })

      {:ok, view, html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      assert html =~ "Delete Me"
      assert html =~ "1 step"

      view |> render_click("delete_step", %{"id" => step.id})

      html = render(view)
      assert html =~ "Step removed."
      refute html =~ "Delete Me"
      assert html =~ "0 steps"
    end

    test "rejects deleting step from another workflow", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      other_workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      other_step =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: other_workflow.id,
          agent_definition_id: agent_def.id,
          position: 1
        })

      {:ok, view, _html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      html = view |> render_click("delete_step", %{"id" => other_step.id})
      assert html =~ "Step not found"
    end
  end

  # ---------------------------------------------------------------------------
  # Reorder steps
  # ---------------------------------------------------------------------------

  describe "reorder steps" do
    test "moves step up", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      _step1 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          name: "Alpha Step",
          position: 1
        })

      step2 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          name: "Beta Step",
          position: 2
        })

      {:ok, view, _html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      # Move Beta up (position 2 -> 1)
      view |> render_click("move_up", %{"id" => step2.id})

      # Verify the steps were reordered - Beta should now be position 1
      steps = Swarmshield.Workflows.list_workflow_steps(workflow.id)
      assert Enum.map(steps, & &1.name) == ["Beta Step", "Alpha Step"]
    end

    test "moves step down", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      step1 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          name: "First",
          position: 1
        })

      _step2 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          name: "Second",
          position: 2
        })

      {:ok, view, _html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      # Move First down (position 1 -> 2)
      view |> render_click("move_down", %{"id" => step1.id})

      steps = Swarmshield.Workflows.list_workflow_steps(workflow.id)
      assert Enum.map(steps, & &1.name) == ["Second", "First"]
    end

    test "move up at top is no-op", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      step1 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          name: "Top Step",
          position: 1
        })

      {:ok, view, _html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      # Move the top step up - should be a no-op
      view |> render_click("move_up", %{"id" => step1.id})

      steps = Swarmshield.Workflows.list_workflow_steps(workflow.id)
      assert hd(steps).name == "Top Step"
    end

    test "move down at bottom is no-op", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      step1 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          name: "Bottom Step",
          position: 1
        })

      {:ok, view, _html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      # Move the only step down - should be a no-op
      view |> render_click("move_down", %{"id" => step1.id})

      steps = Swarmshield.Workflows.list_workflow_steps(workflow.id)
      assert hd(steps).name == "Bottom Step"
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
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin])

      wf = workflow_fixture(%{workspace_id: Plug.Conn.get_session(conn2, :current_workspace_id)})

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/admin/workflows/#{wf.id}")
    end

    test "hides add step form without workflows:update permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, workspace2} = restricted_conn(conn, [perms.admin, perms.view])
      wf = workflow_fixture(%{workspace_id: workspace2.id})

      {:ok, _view, html} = live(conn2, ~p"/admin/workflows/#{wf.id}")

      refute html =~ "Add Pipeline Step"
      refute html =~ "step-form"
    end

    test "hides edit button without workflows:update permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, workspace2} = restricted_conn(conn, [perms.admin, perms.view])
      wf = workflow_fixture(%{workspace_id: workspace2.id})

      {:ok, _view, html} = live(conn2, ~p"/admin/workflows/#{wf.id}")

      refute html =~ "Edit"
    end

    test "rejects add step without workflows:update permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, workspace2} = restricted_conn(conn, [perms.admin, perms.view])
      wf = workflow_fixture(%{workspace_id: workspace2.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace2.id})

      {:ok, view, _html} = live(conn2, ~p"/admin/workflows/#{wf.id}")

      html =
        view
        |> render_click("add_step", %{
          "workflow_step" => %{
            "name" => "Sneaky Step",
            "agent_definition_id" => agent_def.id,
            "execution_mode" => "sequential",
            "timeout_seconds" => "120"
          }
        })

      assert html =~ "Unauthorized"
    end

    test "rejects delete step without workflows:update permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, workspace2} = restricted_conn(conn, [perms.admin, perms.view])
      wf = workflow_fixture(%{workspace_id: workspace2.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace2.id})

      step =
        workflow_step_fixture(%{
          workspace_id: workspace2.id,
          workflow_id: wf.id,
          agent_definition_id: agent_def.id,
          position: 1
        })

      {:ok, view, _html} = live(conn2, ~p"/admin/workflows/#{wf.id}")

      html = view |> render_click("delete_step", %{"id" => step.id})
      assert html =~ "Unauthorized"
    end

    test "rejects move without workflows:update permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, workspace2} = restricted_conn(conn, [perms.admin, perms.view])
      wf = workflow_fixture(%{workspace_id: workspace2.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace2.id})

      step =
        workflow_step_fixture(%{
          workspace_id: workspace2.id,
          workflow_id: wf.id,
          agent_definition_id: agent_def.id,
          position: 1
        })

      {:ok, view, _html} = live(conn2, ~p"/admin/workflows/#{wf.id}")

      html = view |> render_click("move_up", %{"id" => step.id})
      assert html =~ "Unauthorized"
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub: real-time updates from other admin users
  # ---------------------------------------------------------------------------

  describe "pubsub real-time updates" do
    test "receives step_created broadcast", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id, name: "Remote Agent"})

      {:ok, view, _html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      step =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          name: "Remote Step",
          position: 1
        })

      step = Swarmshield.Repo.preload(step, [:agent_definition, :prompt_template])

      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "workflow_steps:#{workflow.id}",
        {:step_created, step}
      )

      html = render(view)
      assert html =~ "Remote Step"
    end

    test "receives step_deleted broadcast", %{conn: conn, workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      step =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          name: "Will Be Removed",
          position: 1
        })

      {:ok, view, html} = live(conn, ~p"/admin/workflows/#{workflow.id}")

      assert html =~ "Will Be Removed"

      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "workflow_steps:#{workflow.id}",
        {:step_deleted, step}
      )

      html = render(view)
      refute html =~ "Will Be Removed"
    end
  end
end
