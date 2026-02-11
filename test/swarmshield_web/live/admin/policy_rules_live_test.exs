defmodule SwarmshieldWeb.Admin.PolicyRulesLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.PoliciesFixtures

  # ---------------------------------------------------------------------------
  # Setup: user with admin:access + policy permissions
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
  # Index: mount and display
  # ---------------------------------------------------------------------------

  describe "index - mount and display" do
    test "renders policy rules page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/policy-rules")

      assert html =~ "Policy Rules"
      assert html =~ "0 rules configured"
      assert html =~ "No policy rules configured"
      assert has_element?(view, "a", "New Rule")
    end

    test "lists existing rules with badges", %{conn: conn, workspace: workspace} do
      _r1 =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          name: "Rate Limit Rule",
          rule_type: :rate_limit,
          action: :flag
        })

      _r2 =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          name: "Block Rule",
          rule_type: :blocklist,
          action: :block,
          config: %{"values" => ["bad_agent"]}
        })

      {:ok, _view, html} = live(conn, ~p"/admin/policy-rules")

      assert html =~ "Rate Limit Rule"
      assert html =~ "Block Rule"
      assert html =~ "2 rules"
      assert html =~ "Rate Limit"
      assert html =~ "Blocklist"
      assert html =~ "Flag"
      assert html =~ "Block"
      refute html =~ "No policy rules configured"
    end

    test "shows action badges with correct colors", %{conn: conn, workspace: workspace} do
      _allow =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          action: :allow,
          config: %{"max_events" => 10, "window_seconds" => 60}
        })

      _flag = policy_rule_fixture(%{workspace_id: workspace.id, action: :flag})

      _block =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          action: :block,
          rule_type: :blocklist,
          config: %{"values" => ["x"]}
        })

      {:ok, _view, html} = live(conn, ~p"/admin/policy-rules")

      assert html =~ "Allow"
      assert html =~ "Flag"
      assert html =~ "Block"
    end

    test "disabled rules shown with muted styling", %{conn: conn, workspace: workspace} do
      _enabled = policy_rule_fixture(%{workspace_id: workspace.id, enabled: true})
      _disabled = policy_rule_fixture(%{workspace_id: workspace.id, enabled: false})

      {:ok, _view, html} = live(conn, ~p"/admin/policy-rules")

      assert html =~ "Enabled"
      assert html =~ "Disabled"
      assert html =~ "opacity-50"
    end
  end

  # ---------------------------------------------------------------------------
  # Create rule
  # ---------------------------------------------------------------------------

  describe "create rule" do
    test "navigates to new rule form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules")

      view |> element("a", "New Rule") |> render_click()

      assert_patch(view, ~p"/admin/policy-rules/new")
      assert render(view) =~ "New Policy Rule"
    end

    test "creates rate_limit rule with valid data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules/new")

      # Set config fields via blur events
      view |> render_click("update_config", %{"field" => "cfg_max_events", "value" => "100"})
      view |> render_click("update_config", %{"field" => "cfg_window_seconds", "value" => "60"})

      view
      |> form("#rule-form", %{
        policy_rule: %{
          name: "My Rate Limiter",
          rule_type: "rate_limit",
          action: "flag",
          priority: "10",
          enabled: "true"
        }
      })
      |> render_submit()

      assert_patch(view, "/admin/policy-rules")
      html = render(view)
      assert html =~ "Policy rule created."
      assert html =~ "My Rate Limiter"
    end

    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules/new")

      assert view
             |> form("#rule-form", %{policy_rule: %{name: ""}})
             |> render_change() =~ "can&#39;t be blank"
    end

    test "shows dynamic config for rate_limit type", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/policy-rules/new")

      assert html =~ "Max Events"
      assert html =~ "Window (seconds)"
    end

    test "shows dynamic config for pattern_match type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules/new")

      html =
        view
        |> form("#rule-form", %{policy_rule: %{rule_type: "pattern_match"}})
        |> render_change()

      assert html =~ "detection rules"
    end

    test "shows dynamic config for blocklist type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules/new")

      html =
        view
        |> form("#rule-form", %{policy_rule: %{rule_type: "blocklist"}})
        |> render_change()

      assert html =~ "Values (one per line)"
      assert html =~ "Blocked values"
    end

    test "shows dynamic config for payload_size type", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules/new")

      html =
        view
        |> form("#rule-form", %{policy_rule: %{rule_type: "payload_size"}})
        |> render_change()

      assert html =~ "Max Content (bytes)"
      assert html =~ "Max Payload (bytes)"
    end

    test "changing rule_type resets config fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules/new")

      # Start with rate_limit, set values
      view |> render_click("update_config", %{"field" => "cfg_max_events", "value" => "50"})

      # Switch to blocklist
      html =
        view
        |> form("#rule-form", %{policy_rule: %{rule_type: "blocklist"}})
        |> render_change()

      # Should show blocklist config, not rate_limit config
      assert html =~ "Values (one per line)"
      refute html =~ "Max Events"
    end
  end

  # ---------------------------------------------------------------------------
  # Edit rule
  # ---------------------------------------------------------------------------

  describe "edit rule" do
    test "navigates to edit form and displays current values", %{
      conn: conn,
      workspace: workspace
    } do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          name: "Original Rule",
          description: "Original desc",
          rule_type: :rate_limit,
          action: :flag,
          priority: 15
        })

      {:ok, _view, html} = live(conn, ~p"/admin/policy-rules/#{rule.id}/edit")

      assert html =~ "Edit Policy Rule"
      assert html =~ "Original Rule"
      assert html =~ "Original desc"
    end

    test "updates rule with valid changes", %{conn: conn, workspace: workspace} do
      rule = policy_rule_fixture(%{workspace_id: workspace.id, name: "Old Rule"})

      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules/#{rule.id}/edit")

      view
      |> form("#rule-form", %{
        policy_rule: %{name: "Updated Rule", description: "New description"}
      })
      |> render_submit()

      assert_patch(view, "/admin/policy-rules")
      html = render(view)
      assert html =~ "Policy rule updated."
      assert html =~ "Updated Rule"
    end

    test "prevents editing rule from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_rule = policy_rule_fixture(%{workspace_id: other_workspace.id})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/admin/policy-rules/#{other_rule.id}/edit")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Toggle enabled
  # ---------------------------------------------------------------------------

  describe "toggle enabled" do
    test "toggles rule enabled status", %{conn: conn, workspace: workspace} do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          enabled: true,
          name: "Toggle Me"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules")

      view |> render_click("toggle_enabled", %{"id" => rule.id})

      html = render(view)
      assert html =~ "Disabled"
    end
  end

  # ---------------------------------------------------------------------------
  # Delete rule
  # ---------------------------------------------------------------------------

  describe "delete rule" do
    test "deletes a rule", %{conn: conn, workspace: workspace} do
      rule = policy_rule_fixture(%{workspace_id: workspace.id, name: "Delete Me"})

      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules")

      assert render(view) =~ "Delete Me"

      view |> render_click("delete", %{"id" => rule.id})

      html = render(view)
      assert html =~ "Policy rule deleted"
      refute html =~ "Delete Me"
    end

    test "shows error when deleting rule with violations", %{
      conn: conn,
      workspace: workspace
    } do
      rule = policy_rule_fixture(%{workspace_id: workspace.id, name: "Violated Rule"})

      # Create a violation referencing this rule
      _violation =
        policy_violation_fixture(%{
          workspace_id: workspace.id,
          policy_rule_id: rule.id
        })

      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules")

      assert render(view) =~ "Violated Rule"

      html = view |> render_click("delete", %{"id" => rule.id})
      assert html =~ "Cannot delete"
    end

    test "prevents deleting rule from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_rule = policy_rule_fixture(%{workspace_id: other_workspace.id})

      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules")

      html = view |> render_click("delete", %{"id" => other_rule.id})
      assert html =~ "Rule not found"
    end
  end

  # ---------------------------------------------------------------------------
  # Security: permission checks
  # ---------------------------------------------------------------------------

  describe "security" do
    test "redirects when user lacks policies:view permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin])

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/admin/policy-rules")
    end

    test "hides create button without policies:create permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, _view, html} = live(conn2, ~p"/admin/policy-rules")

      refute html =~ "New Rule"
    end

    test "rejects create action without policies:create permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, view, _html} = live(conn2, ~p"/admin/policy-rules/new")

      view |> render_click("update_config", %{"field" => "cfg_max_events", "value" => "10"})
      view |> render_click("update_config", %{"field" => "cfg_window_seconds", "value" => "60"})

      html =
        view
        |> form("#rule-form", %{
          policy_rule: %{name: "Sneaky Create", rule_type: "rate_limit", action: "flag"}
        })
        |> render_submit()

      assert html =~ "Unauthorized"
    end

    test "rejects delete action without policies:delete permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      rule = policy_rule_fixture(%{workspace_id: workspace2.id})

      {:ok, view, _html} = live(conn2, ~p"/admin/policy-rules")

      html = view |> render_click("delete", %{"id" => rule.id})
      assert html =~ "Unauthorized"
    end

    test "scopes data to current workspace only", %{conn: conn, workspace: workspace} do
      _our = policy_rule_fixture(%{workspace_id: workspace.id, name: "Our Rule"})

      other_workspace = workspace_fixture()
      _other = policy_rule_fixture(%{workspace_id: other_workspace.id, name: "Other Rule"})

      {:ok, _view, html} = live(conn, ~p"/admin/policy-rules")

      assert html =~ "Our Rule"
      refute html =~ "Other Rule"
      assert html =~ "1 rule configured"
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub: ETS cache refresh on changes
  # ---------------------------------------------------------------------------

  describe "pubsub - cache refresh on changes" do
    test "creating rule triggers PubSub broadcast", %{conn: conn, workspace: workspace} do
      # Subscribe to policy_rules topic
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "policy_rules:#{workspace.id}")

      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules/new")

      view |> render_click("update_config", %{"field" => "cfg_max_events", "value" => "50"})
      view |> render_click("update_config", %{"field" => "cfg_window_seconds", "value" => "30"})

      view
      |> form("#rule-form", %{
        policy_rule: %{
          name: "Broadcast Test",
          rule_type: "rate_limit",
          action: "flag",
          priority: "5"
        }
      })
      |> render_submit()

      assert_receive {:policy_rules_changed, :created, _rule_id}, 1000
    end

    test "deleting rule triggers PubSub broadcast", %{conn: conn, workspace: workspace} do
      rule = policy_rule_fixture(%{workspace_id: workspace.id, name: "To Delete"})

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "policy_rules:#{workspace.id}")

      {:ok, view, _html} = live(conn, ~p"/admin/policy-rules")

      view |> render_click("delete", %{"id" => rule.id})

      assert_receive {:policy_rules_changed, :deleted, _rule_id}, 1000
    end
  end
end
