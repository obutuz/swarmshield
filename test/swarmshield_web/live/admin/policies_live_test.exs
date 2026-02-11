defmodule SwarmshieldWeb.Admin.PoliciesLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures

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

  # ---------------------------------------------------------------------------
  # Helper: build conn for restricted user
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
    test "renders policies page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/consensus-policies")

      assert html =~ "Consensus Policies"
      assert html =~ "0 policies configured"
      assert html =~ "No consensus policies configured"
      assert has_element?(view, "a", "New Policy")
    end

    test "lists existing policies", %{conn: conn, workspace: workspace} do
      _p1 = consensus_policy_fixture(%{workspace_id: workspace.id, name: "Majority Policy"})
      _p2 = consensus_policy_fixture(%{workspace_id: workspace.id, name: "Super Policy"})

      {:ok, _view, html} = live(conn, ~p"/admin/consensus-policies")

      assert html =~ "Majority Policy"
      assert html =~ "Super Policy"
      assert html =~ "2 policies"
      refute html =~ "No consensus policies configured"
    end

    test "displays strategy badges", %{conn: conn, workspace: workspace} do
      _p1 = consensus_policy_fixture(%{workspace_id: workspace.id, strategy: :majority})
      _p2 = consensus_policy_fixture(%{workspace_id: workspace.id, strategy: :supermajority})
      _p3 = consensus_policy_fixture(%{workspace_id: workspace.id, strategy: :unanimous})
      _p4 = consensus_policy_fixture(%{workspace_id: workspace.id, strategy: :weighted})

      {:ok, _view, html} = live(conn, ~p"/admin/consensus-policies")

      assert html =~ "Majority"
      assert html =~ "Supermajority"
      assert html =~ "Unanimous"
      assert html =~ "Weighted"
    end

    test "displays enabled/disabled status badges", %{conn: conn, workspace: workspace} do
      _enabled = consensus_policy_fixture(%{workspace_id: workspace.id, enabled: true})
      _disabled = consensus_policy_fixture(%{workspace_id: workspace.id, enabled: false})

      {:ok, _view, html} = live(conn, ~p"/admin/consensus-policies")

      assert html =~ "Enabled"
      assert html =~ "Disabled"
    end

    test "displays threshold for majority policies", %{conn: conn, workspace: workspace} do
      _p =
        consensus_policy_fixture(%{
          workspace_id: workspace.id,
          strategy: :majority,
          threshold: 0.5
        })

      {:ok, _view, html} = live(conn, ~p"/admin/consensus-policies")

      assert html =~ "50.0%"
    end
  end

  # ---------------------------------------------------------------------------
  # Create policy
  # ---------------------------------------------------------------------------

  describe "create policy" do
    test "navigates to new policy form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies")

      view
      |> element("a", "New Policy")
      |> render_click()

      assert_patch(view, ~p"/admin/consensus-policies/new")
      assert render(view) =~ "New Consensus Policy"
      assert render(view) =~ "Configure voting strategy"
    end

    test "creates policy with valid data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies/new")

      view
      |> form("#policy-form", %{
        consensus_policy: %{
          name: "My Majority Policy",
          description: "Standard majority vote",
          strategy: "majority",
          threshold: "0.5",
          enabled: "true"
        }
      })
      |> render_submit()

      assert_patch(view, "/admin/consensus-policies")
      html = render(view)
      assert html =~ "Consensus policy created."
      assert html =~ "My Majority Policy"
    end

    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies/new")

      assert view
             |> form("#policy-form", %{
               consensus_policy: %{name: ""}
             })
             |> render_change() =~ "can&#39;t be blank"
    end

    test "creates policy with threshold=0 for majority strategy", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies/new")

      view
      |> form("#policy-form", %{
        consensus_policy: %{
          name: "Zero Threshold Policy",
          strategy: "majority",
          threshold: "0"
        }
      })
      |> render_submit()

      assert_patch(view, "/admin/consensus-policies")
      html = render(view)
      assert html =~ "Consensus policy created."
      assert html =~ "Zero Threshold Policy"
    end

    test "shows threshold field for majority strategy", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/consensus-policies/new")

      # Default strategy is majority, so threshold should be visible
      assert html =~ "Threshold"
      assert html =~ "Fraction of votes needed"
    end

    test "hides threshold for unanimous strategy", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies/new")

      # Change strategy to unanimous
      html =
        view
        |> form("#policy-form", %{
          consensus_policy: %{strategy: "unanimous"}
        })
        |> render_change()

      refute html =~ "Fraction of votes needed"
    end

    test "shows weights editor for weighted strategy", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies/new")

      # Change strategy to weighted
      html =
        view
        |> form("#policy-form", %{
          consensus_policy: %{strategy: "weighted"}
        })
        |> render_change()

      assert html =~ "Agent Weights"
      assert html =~ "Add Weight"
    end
  end

  # ---------------------------------------------------------------------------
  # Edit policy
  # ---------------------------------------------------------------------------

  describe "edit policy" do
    test "navigates to edit form and displays current values", %{
      conn: conn,
      workspace: workspace
    } do
      policy =
        consensus_policy_fixture(%{
          workspace_id: workspace.id,
          name: "Original Policy",
          description: "Original desc",
          strategy: :supermajority,
          threshold: 0.67
        })

      {:ok, _view, html} = live(conn, ~p"/admin/consensus-policies/#{policy.id}/edit")

      assert html =~ "Edit Consensus Policy"
      assert html =~ "Original Policy"
      assert html =~ "Original desc"
    end

    test "updates policy with valid changes", %{conn: conn, workspace: workspace} do
      policy = consensus_policy_fixture(%{workspace_id: workspace.id, name: "Old Policy"})

      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies/#{policy.id}/edit")

      view
      |> form("#policy-form", %{
        consensus_policy: %{name: "Updated Policy", description: "New description"}
      })
      |> render_submit()

      assert_patch(view, "/admin/consensus-policies")
      html = render(view)
      assert html =~ "Consensus policy updated."
      assert html =~ "Updated Policy"
    end

    test "prevents editing policy from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_policy = consensus_policy_fixture(%{workspace_id: other_workspace.id})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/admin/consensus-policies/#{other_policy.id}/edit")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Toggle enabled
  # ---------------------------------------------------------------------------

  describe "toggle enabled" do
    test "toggles policy enabled status", %{conn: conn, workspace: workspace} do
      policy =
        consensus_policy_fixture(%{
          workspace_id: workspace.id,
          enabled: true,
          name: "Toggle Me"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies")

      view |> render_click("toggle_enabled", %{"id" => policy.id})

      html = render(view)
      assert html =~ "Disabled"
    end

    test "prevents toggling policy from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()

      other_policy =
        consensus_policy_fixture(%{
          workspace_id: other_workspace.id,
          enabled: true,
          name: "Other Policy"
        })

      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies")

      html = view |> render_click("toggle_enabled", %{"id" => other_policy.id})
      assert html =~ "Policy not found"
    end
  end

  # ---------------------------------------------------------------------------
  # Delete policy
  # ---------------------------------------------------------------------------

  describe "delete policy" do
    test "deletes a policy", %{conn: conn, workspace: workspace} do
      policy = consensus_policy_fixture(%{workspace_id: workspace.id, name: "Delete Me"})

      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies")

      assert render(view) =~ "Delete Me"

      view |> render_click("delete", %{"id" => policy.id})

      html = render(view)
      assert html =~ "Consensus policy deleted"
      refute html =~ "Delete Me"
    end

    test "prevents deleting policy from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_policy = consensus_policy_fixture(%{workspace_id: other_workspace.id})

      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies")

      html = view |> render_click("delete", %{"id" => other_policy.id})
      assert html =~ "Policy not found"
    end

    test "shows error when deleting policy referenced by sessions", %{
      conn: conn,
      workspace: workspace
    } do
      policy = consensus_policy_fixture(%{workspace_id: workspace.id, name: "Referenced Policy"})

      # Create an analysis session referencing this policy
      _session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          consensus_policy_id: policy.id
        })

      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies")

      assert render(view) =~ "Referenced Policy"

      html = view |> render_click("delete", %{"id" => policy.id})
      assert html =~ "Cannot delete: policy is referenced by analysis sessions"
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
               live(conn2, ~p"/admin/consensus-policies")
    end

    test "hides create button without policies:create permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, _view, html} = live(conn2, ~p"/admin/consensus-policies")

      refute html =~ "New Policy"
    end

    test "rejects create action without policies:create permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, view, _html} = live(conn2, ~p"/admin/consensus-policies/new")

      html =
        view
        |> form("#policy-form", %{
          consensus_policy: %{name: "Sneaky Create", strategy: "majority"}
        })
        |> render_submit()

      assert html =~ "Unauthorized"
    end

    test "rejects delete action without policies:delete permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      policy = consensus_policy_fixture(%{workspace_id: workspace2.id})

      {:ok, view, _html} = live(conn2, ~p"/admin/consensus-policies")

      html = view |> render_click("delete", %{"id" => policy.id})
      assert html =~ "Unauthorized"
    end

    test "scopes data to current workspace only", %{conn: conn, workspace: workspace} do
      _our = consensus_policy_fixture(%{workspace_id: workspace.id, name: "Our Policy"})

      other_workspace = workspace_fixture()
      _other = consensus_policy_fixture(%{workspace_id: other_workspace.id, name: "Other Policy"})

      {:ok, _view, html} = live(conn, ~p"/admin/consensus-policies")

      assert html =~ "Our Policy"
      refute html =~ "Other Policy"
      assert html =~ "1 policy configured"
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub: real-time updates from other admin users
  # ---------------------------------------------------------------------------

  describe "pubsub real-time updates" do
    test "receives consensus_policy_created broadcast", %{conn: conn, workspace: workspace} do
      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies")

      policy = consensus_policy_fixture(%{workspace_id: workspace.id, name: "Remote Policy"})

      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "consensus_policies:#{workspace.id}",
        {:consensus_policy_created, policy}
      )

      html = render(view)
      assert html =~ "Remote Policy"
    end

    test "receives consensus_policy_deleted broadcast", %{conn: conn, workspace: workspace} do
      policy = consensus_policy_fixture(%{workspace_id: workspace.id, name: "Soon Deleted"})

      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies")
      assert render(view) =~ "Soon Deleted"

      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "consensus_policies:#{workspace.id}",
        {:consensus_policy_deleted, policy}
      )

      html = render(view)
      refute html =~ "Soon Deleted"
    end
  end

  # ---------------------------------------------------------------------------
  # Conditional form fields
  # ---------------------------------------------------------------------------

  describe "conditional form fields" do
    test "threshold field hidden for unanimous strategy", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies/new")

      html =
        view
        |> form("#policy-form", %{consensus_policy: %{strategy: "unanimous"}})
        |> render_change()

      refute html =~ "Threshold (0.0 - 1.0)"
    end

    test "threshold field shown for supermajority strategy", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies/new")

      html =
        view
        |> form("#policy-form", %{consensus_policy: %{strategy: "supermajority"}})
        |> render_change()

      assert html =~ "Threshold (0.0 - 1.0)"
      assert html =~ "two-thirds"
    end

    test "weights editor shown for weighted strategy", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies/new")

      html =
        view
        |> form("#policy-form", %{consensus_policy: %{strategy: "weighted"}})
        |> render_change()

      assert html =~ "Agent Weights"
      assert html =~ "Agent role"
    end

    test "weights editor hidden for majority strategy", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/admin/consensus-policies/new")

      refute html =~ "Agent Weights"
    end

    test "validates threshold is a number", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/consensus-policies/new")

      html =
        view
        |> form("#policy-form", %{
          consensus_policy: %{name: "Test", strategy: "majority", threshold: "abc"}
        })
        |> render_change()

      assert html =~ "is invalid"
    end
  end
end
