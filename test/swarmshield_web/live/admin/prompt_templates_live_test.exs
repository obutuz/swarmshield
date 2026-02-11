defmodule SwarmshieldWeb.Admin.PromptTemplatesLiveTest do
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
    test "renders prompt templates page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/prompt-templates")

      assert html =~ "Prompt Templates"
      assert html =~ "0 templates configured"
      assert html =~ "No prompt templates configured"
      assert has_element?(view, "a", "New Template")
    end

    test "lists existing templates with variable counts", %{conn: conn, workspace: workspace} do
      _t1 =
        prompt_template_fixture(%{
          workspace_id: workspace.id,
          name: "Analysis Template",
          template: "Analyze {{event_type}} event: {{content}}",
          category: "analysis"
        })

      _t2 =
        prompt_template_fixture(%{
          workspace_id: workspace.id,
          name: "Summary Template",
          template: "Summarize the following",
          category: "summary"
        })

      {:ok, _view, html} = live(conn, ~p"/admin/prompt-templates")

      assert html =~ "Analysis Template"
      assert html =~ "Summary Template"
      assert html =~ "2 templates"
    end
  end

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  describe "create template" do
    test "navigates to new template form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/prompt-templates")

      view |> element("a", "New Template") |> render_click()

      assert_patch(view, ~p"/admin/prompt-templates/new")
      assert render(view) =~ "New Prompt Template"
    end

    test "creates template with valid data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/prompt-templates/new")

      view
      |> form("#prompt-template-form", %{
        prompt_template: %{
          name: "My New Template",
          template: "Hello {{name}}, analyze {{content}}",
          category: "analysis",
          enabled: "true"
        }
      })
      |> render_submit()

      assert_patch(view, "/admin/prompt-templates")
      html = render(view)
      assert html =~ "Prompt template created."
      assert html =~ "My New Template"
    end

    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/prompt-templates/new")

      assert view
             |> form("#prompt-template-form", %{prompt_template: %{name: ""}})
             |> render_change() =~ "can&#39;t be blank"
    end

    test "detects variables in real-time as user types", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/prompt-templates/new")

      html =
        view
        |> form("#prompt-template-form", %{
          prompt_template: %{template: "Hello {{name}}, your {{role}} is {{status}}"}
        })
        |> render_change()

      assert html =~ "Detected Variables (3)"
      assert html =~ "{{name}}"
      assert html =~ "{{role}}"
      assert html =~ "{{status}}"
    end

    test "deduplicates variables", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/prompt-templates/new")

      html =
        view
        |> form("#prompt-template-form", %{
          prompt_template: %{template: "{{name}} and {{name}} again"}
        })
        |> render_change()

      assert html =~ "Detected Variables (1)"
    end
  end

  # ---------------------------------------------------------------------------
  # Edit
  # ---------------------------------------------------------------------------

  describe "edit template" do
    test "displays current values in edit form", %{conn: conn, workspace: workspace} do
      tmpl =
        prompt_template_fixture(%{
          workspace_id: workspace.id,
          name: "Original Template",
          description: "Original desc",
          template: "Hello {{world}}"
        })

      {:ok, _view, html} = live(conn, ~p"/admin/prompt-templates/#{tmpl.id}/edit")

      assert html =~ "Edit Prompt Template"
      assert html =~ "Original Template"
      assert html =~ "Original desc"
      assert html =~ "Hello {{world}}"
    end

    test "updates template with valid changes", %{conn: conn, workspace: workspace} do
      tmpl = prompt_template_fixture(%{workspace_id: workspace.id, name: "Old Template"})

      {:ok, view, _html} = live(conn, ~p"/admin/prompt-templates/#{tmpl.id}/edit")

      view
      |> form("#prompt-template-form", %{
        prompt_template: %{name: "Updated Template"}
      })
      |> render_submit()

      assert_patch(view, "/admin/prompt-templates")
      html = render(view)
      assert html =~ "Prompt template updated."
      assert html =~ "Updated Template"
    end

    test "prevents editing template from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_tmpl = prompt_template_fixture(%{workspace_id: other_workspace.id})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/admin/prompt-templates/#{other_tmpl.id}/edit")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Delete
  # ---------------------------------------------------------------------------

  describe "delete template" do
    test "deletes a template", %{conn: conn, workspace: workspace} do
      tmpl = prompt_template_fixture(%{workspace_id: workspace.id, name: "Delete Me"})

      {:ok, view, _html} = live(conn, ~p"/admin/prompt-templates")

      assert render(view) =~ "Delete Me"

      view |> render_click("delete", %{"id" => tmpl.id})

      html = render(view)
      assert html =~ "Prompt template deleted."
      refute html =~ "Delete Me"
    end

    test "prevents deleting template used in workflow steps", %{
      conn: conn,
      workspace: workspace
    } do
      tmpl = prompt_template_fixture(%{workspace_id: workspace.id, name: "In Use"})
      defn = agent_definition_fixture(%{workspace_id: workspace.id})
      workflow = workflow_fixture(%{workspace_id: workspace.id})

      workflow_step_fixture(%{
        workflow_id: workflow.id,
        agent_definition_id: defn.id,
        prompt_template_id: tmpl.id
      })

      {:ok, view, _html} = live(conn, ~p"/admin/prompt-templates")

      view |> render_click("delete", %{"id" => tmpl.id})

      html = render(view)
      assert html =~ "Cannot delete"
      assert html =~ "In Use"
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
               live(conn2, ~p"/admin/prompt-templates")
    end

    test "rejects create action without agents:create permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, view, _html} = live(conn2, ~p"/admin/prompt-templates/new")

      html =
        view
        |> form("#prompt-template-form", %{
          prompt_template: %{
            name: "Sneaky Template",
            template: "test"
          }
        })
        |> render_submit()

      assert html =~ "Unauthorized"
    end

    test "scopes data to current workspace only", %{conn: conn, workspace: workspace} do
      _our = prompt_template_fixture(%{workspace_id: workspace.id, name: "Our Template"})

      other_workspace = workspace_fixture()

      _other =
        prompt_template_fixture(%{workspace_id: other_workspace.id, name: "Other Template"})

      {:ok, _view, html} = live(conn, ~p"/admin/prompt-templates")

      assert html =~ "Our Template"
      refute html =~ "Other Template"
    end
  end
end
