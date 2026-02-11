defmodule SwarmshieldWeb.Admin.DetectionRulesLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.PoliciesFixtures

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "admin_role_#{System.unique_integer([:positive])}"})

    admin_perm = permission_fixture(%{resource: "admin", action: "access"})
    role_permission_fixture(role, admin_perm)

    view_perm = permission_fixture(%{resource: "policies", action: "view"})
    create_perm = permission_fixture(%{resource: "policies", action: "create"})
    update_perm = permission_fixture(%{resource: "policies", action: "update"})
    delete_perm = permission_fixture(%{resource: "policies", action: "delete"})

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
    test "renders detection rules page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/detection-rules")

      assert html =~ "Detection Rules"
      assert html =~ "0 rules configured"
      assert html =~ "No detection rules configured"
      assert has_element?(view, "a", "New Rule")
    end

    test "lists existing rules with badges", %{conn: conn, workspace: workspace} do
      _r1 =
        detection_rule_fixture(%{
          workspace_id: workspace.id,
          name: "PII Detector",
          detection_type: :regex,
          severity: :high,
          category: "pii"
        })

      _r2 =
        detection_rule_fixture(%{
          workspace_id: workspace.id,
          name: "Profanity Filter",
          detection_type: :keyword,
          severity: :medium,
          category: "profanity"
        })

      {:ok, _view, html} = live(conn, ~p"/admin/detection-rules")

      assert html =~ "PII Detector"
      assert html =~ "Profanity Filter"
      assert html =~ "2 rules"
      assert html =~ "Regex"
      assert html =~ "Keyword"
      assert html =~ "High"
      assert html =~ "Medium"
    end

    test "displays severity badges", %{conn: conn, workspace: workspace} do
      _low = detection_rule_fixture(%{workspace_id: workspace.id, severity: :low})
      _critical = detection_rule_fixture(%{workspace_id: workspace.id, severity: :critical})

      {:ok, _view, html} = live(conn, ~p"/admin/detection-rules")

      assert html =~ "Low"
      assert html =~ "Critical"
    end
  end

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  describe "create rule" do
    test "navigates to new rule form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/detection-rules")

      view |> element("a", "New Rule") |> render_click()

      assert_patch(view, ~p"/admin/detection-rules/new")
      assert render(view) =~ "New Detection Rule"
    end

    test "creates regex rule with valid data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/detection-rules/new")

      view
      |> form("#detection-rule-form", %{
        detection_rule: %{
          name: "My Regex Rule",
          detection_type: "regex",
          pattern: "\\b(password|secret)\\b",
          severity: "high",
          category: "credentials",
          enabled: "true"
        }
      })
      |> render_submit()

      assert_patch(view, "/admin/detection-rules")
      html = render(view)
      assert html =~ "Detection rule created."
      assert html =~ "My Regex Rule"
    end

    test "creates keyword rule with valid data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/detection-rules/new")

      # Switch to keyword type
      view
      |> form("#detection-rule-form", %{
        detection_rule: %{detection_type: "keyword"}
      })
      |> render_change()

      # Set keywords via blur event
      view |> render_click("update_keywords", %{"value" => "password, secret, api_key"})

      view
      |> form("#detection-rule-form", %{
        detection_rule: %{
          name: "Keyword Rule",
          detection_type: "keyword",
          severity: "medium",
          category: "credentials"
        }
      })
      |> render_submit()

      assert_patch(view, "/admin/detection-rules")
      html = render(view)
      assert html =~ "Detection rule created."
      assert html =~ "Keyword Rule"
    end

    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/detection-rules/new")

      assert view
             |> form("#detection-rule-form", %{detection_rule: %{name: ""}})
             |> render_change() =~ "can&#39;t be blank"
    end

    test "shows regex pattern field for regex type", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/detection-rules/new")

      assert html =~ "Regex Pattern"
      assert html =~ "Test Pattern"
    end

    test "shows keyword field for keyword type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/detection-rules/new")

      html =
        view
        |> form("#detection-rule-form", %{detection_rule: %{detection_type: "keyword"}})
        |> render_change()

      assert html =~ "Keywords"
      assert html =~ "comma or newline separated"
    end

    test "switching detection_type clears pattern/keywords fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/detection-rules/new")

      # Start with regex
      assert render(view) =~ "Regex Pattern"

      # Switch to keyword
      html =
        view
        |> form("#detection-rule-form", %{detection_rule: %{detection_type: "keyword"}})
        |> render_change()

      assert html =~ "Keywords"
      refute html =~ "Regex Pattern"

      # Switch to semantic
      html =
        view
        |> form("#detection-rule-form", %{detection_rule: %{detection_type: "semantic"}})
        |> render_change()

      assert html =~ "Semantic detection"
      refute html =~ "Keywords"
    end

    test "shows error for invalid regex pattern", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/detection-rules/new")

      html =
        view
        |> form("#detection-rule-form", %{
          detection_rule: %{name: "Bad Regex", detection_type: "regex", pattern: "[invalid"}
        })
        |> render_change()

      assert html =~ "Invalid regex"
    end
  end

  # ---------------------------------------------------------------------------
  # Edit
  # ---------------------------------------------------------------------------

  describe "edit rule" do
    test "displays current values in edit form", %{conn: conn, workspace: workspace} do
      rule =
        detection_rule_fixture(%{
          workspace_id: workspace.id,
          name: "Original Rule",
          description: "Original desc",
          detection_type: :regex,
          pattern: "\\btest\\b",
          severity: :high
        })

      {:ok, _view, html} = live(conn, ~p"/admin/detection-rules/#{rule.id}/edit")

      assert html =~ "Edit Detection Rule"
      assert html =~ "Original Rule"
      assert html =~ "Original desc"
    end

    test "updates rule with valid changes", %{conn: conn, workspace: workspace} do
      rule = detection_rule_fixture(%{workspace_id: workspace.id, name: "Old Rule"})

      {:ok, view, _html} = live(conn, ~p"/admin/detection-rules/#{rule.id}/edit")

      view
      |> form("#detection-rule-form", %{
        detection_rule: %{name: "Updated Rule"}
      })
      |> render_submit()

      assert_patch(view, "/admin/detection-rules")
      html = render(view)
      assert html =~ "Detection rule updated."
      assert html =~ "Updated Rule"
    end

    test "prevents editing rule from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_rule = detection_rule_fixture(%{workspace_id: other_workspace.id})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/admin/detection-rules/#{other_rule.id}/edit")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Delete
  # ---------------------------------------------------------------------------

  describe "delete rule" do
    test "deletes a rule", %{conn: conn, workspace: workspace} do
      rule = detection_rule_fixture(%{workspace_id: workspace.id, name: "Delete Me"})

      {:ok, view, _html} = live(conn, ~p"/admin/detection-rules")

      assert render(view) =~ "Delete Me"

      view |> render_click("delete", %{"id" => rule.id})

      html = render(view)
      assert html =~ "Detection rule deleted"
      refute html =~ "Delete Me"
    end
  end

  # ---------------------------------------------------------------------------
  # Security
  # ---------------------------------------------------------------------------

  describe "security" do
    test "redirects when user lacks policies:view permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin])

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/admin/detection-rules")
    end

    test "rejects create action without policies:create permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, view, _html} = live(conn2, ~p"/admin/detection-rules/new")

      html =
        view
        |> form("#detection-rule-form", %{
          detection_rule: %{
            name: "Sneaky",
            detection_type: "regex",
            pattern: "test"
          }
        })
        |> render_submit()

      assert html =~ "Unauthorized"
    end

    test "scopes data to current workspace only", %{conn: conn, workspace: workspace} do
      _our = detection_rule_fixture(%{workspace_id: workspace.id, name: "Our Rule"})

      other_workspace = workspace_fixture()
      _other = detection_rule_fixture(%{workspace_id: other_workspace.id, name: "Other Rule"})

      {:ok, _view, html} = live(conn, ~p"/admin/detection-rules")

      assert html =~ "Our Rule"
      refute html =~ "Other Rule"
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  describe "pubsub - cache refresh" do
    test "creating rule triggers PubSub broadcast", %{conn: conn, workspace: workspace} do
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "detection_rules:#{workspace.id}")

      {:ok, view, _html} = live(conn, ~p"/admin/detection-rules/new")

      view
      |> form("#detection-rule-form", %{
        detection_rule: %{
          name: "Broadcast Test",
          detection_type: "regex",
          pattern: "\\btest\\b",
          severity: "medium"
        }
      })
      |> render_submit()

      assert_receive {:detection_rules_changed, :created, _rule_id}, 1000
    end
  end
end
