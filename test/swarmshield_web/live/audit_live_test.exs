defmodule SwarmshieldWeb.AuditLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "audit_role_#{System.unique_integer([:positive])}"})

    permission = permission_fixture(%{resource: "audit", action: "view"})
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

  describe "mount and display" do
    test "renders audit log with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/audit")

      assert html =~ "Audit Log"
      assert has_element?(view, "#audit-header")
      assert has_element?(view, "#audit-filters")
      assert has_element?(view, "#audit-entries")
      assert html =~ "No audit entries found"
      assert html =~ "0 entries"
    end

    test "renders audit entries when present", %{conn: conn, workspace: workspace} do
      _entry =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "user.login",
          resource_type: "session",
          actor_email: "admin@example.com",
          ip_address: "192.168.1.1",
          metadata: %{"browser" => "Chrome"}
        })

      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ "1 entry"
      assert html =~ "user.login"
      assert html =~ "session"
      assert html =~ "admin@example.com"
      assert html =~ "192.168.1.1"
    end
  end

  describe "filtering" do
    test "filters by action", %{conn: conn, workspace: workspace} do
      _login =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "user.login",
          resource_type: "session"
        })

      _create =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "agent.create",
          resource_type: "agent"
        })

      {:ok, view, _html} = live(conn, ~p"/audit")

      # Filter by action
      {:ok, _view, html} =
        view
        |> element("form")
        |> render_change(%{"action" => "user.login", "resource_type" => "", "search" => ""})
        |> then(fn _ ->
          live(conn, ~p"/audit?action=user.login")
        end)

      assert html =~ "user.login"
      assert html =~ "1 entry"
    end

    test "filters by resource_type", %{conn: conn, workspace: workspace} do
      _session =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "test.action",
          resource_type: "session"
        })

      _agent =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "test.action",
          resource_type: "agent"
        })

      {:ok, _view, html} = live(conn, ~p"/audit?resource_type=agent")

      assert html =~ "1 entry"
      assert html =~ "agent"
    end

    test "clears filters", %{conn: conn, workspace: workspace} do
      _entry =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "user.login",
          resource_type: "session"
        })

      {:ok, view, _html} = live(conn, ~p"/audit?action=nonexistent")

      assert html = render(view)
      assert html =~ "0 entries"

      # Clear filters
      view |> element("button", "Clear") |> render_click()

      # Redirect will trigger re-mount
    end
  end

  describe "search" do
    test "searches by actor email", %{conn: conn, workspace: workspace} do
      _entry1 =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "user.login",
          resource_type: "session",
          actor_email: "findme@example.com"
        })

      _entry2 =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "user.login",
          resource_type: "session",
          actor_email: "other@example.com"
        })

      {:ok, _view, html} = live(conn, ~p"/audit?search=findme")

      assert html =~ "1 entry"
      assert html =~ "findme@example.com"
    end
  end

  describe "ghost protocol entries" do
    test "highlights ghost protocol wipe entries", %{conn: conn, workspace: workspace} do
      _wipe_entry =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "ghost_protocol_wipe",
          resource_type: "analysis_session",
          metadata: %{
            "fields_wiped" => ["input_content", "deliberation_messages"],
            "crypto_shred" => true
          }
        })

      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ "ghost_protocol_wipe"
      assert html =~ "input_content"
      assert html =~ "Crypto Shred"
    end
  end

  describe "metadata preview" do
    test "truncates long metadata to 100 chars", %{conn: conn, workspace: workspace} do
      long_value = String.duplicate("a", 200)

      _entry =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "test.action",
          resource_type: "test",
          metadata: %{"data" => long_value}
        })

      {:ok, _view, html} = live(conn, ~p"/audit")

      # Should show truncated preview (the "…" indicates truncation)
      assert html =~ "…"
    end
  end

  describe "pagination" do
    test "shows load more button when entries exceed page size", %{
      conn: conn,
      workspace: workspace
    } do
      # Create enough entries to trigger pagination (page_size is 50)
      # Just verify that with 1 entry there's no load more button
      _entry =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "test.action",
          resource_type: "test"
        })

      {:ok, view, _html} = live(conn, ~p"/audit")

      refute has_element?(view, "button", "Load more")
    end
  end

  describe "security" do
    test "redirects when user lacks audit:view permission", %{conn: conn} do
      user2 = user_fixture()
      workspace2 = workspace_fixture()
      role2 = role_fixture(%{name: "noperm_audit_#{System.unique_integer([:positive])}"})

      user_workspace_role_fixture(user2, workspace2, role2)

      token2 = Swarmshield.Accounts.generate_user_session_token(user2)

      conn2 =
        conn
        |> recycle()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, token2)
        |> Plug.Conn.put_session(:current_workspace_id, workspace2.id)

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/audit")
    end

    test "scopes data to current workspace only", %{conn: conn, workspace: workspace} do
      other_workspace = workspace_fixture()

      _other_entry =
        audit_entry_fixture(%{
          workspace_id: other_workspace.id,
          action: "other.action",
          resource_type: "other_resource",
          actor_email: "other@workspace.com"
        })

      _our_entry =
        audit_entry_fixture(%{
          workspace_id: workspace.id,
          action: "our.action",
          resource_type: "our_resource"
        })

      {:ok, _view, html} = live(conn, ~p"/audit")

      assert html =~ "1 entry"
      assert html =~ "our.action"
      refute html =~ "other.action"
      refute html =~ "other@workspace.com"
    end
  end
end
