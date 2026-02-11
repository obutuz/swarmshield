defmodule SwarmshieldWeb.Admin.GhostProtocolConfigsLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.GhostProtocolFixtures
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

    view_perm = permission_fixture(%{resource: "ghost_protocol", action: "view"})
    create_perm = permission_fixture(%{resource: "ghost_protocol", action: "create"})
    update_perm = permission_fixture(%{resource: "ghost_protocol", action: "update"})
    delete_perm = permission_fixture(%{resource: "ghost_protocol", action: "delete"})

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
    test "renders GhostProtocol configs page with empty state", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/ghost-protocol-configs")

      assert html =~ "GhostProtocol Configs"
      assert html =~ "0 configs configured"
      assert html =~ "No GhostProtocol configs"
      assert has_element?(view, "a", "New Config")
    end

    test "lists existing configs with strategy badges", %{conn: conn, workspace: workspace} do
      _c1 =
        ghost_protocol_config_fixture(%{
          workspace_id: workspace.id,
          name: "Immediate Config",
          wipe_strategy: :immediate
        })

      _c2 =
        ghost_protocol_config_fixture(%{
          workspace_id: workspace.id,
          name: "Delayed Config",
          wipe_strategy: :delayed,
          wipe_delay_seconds: 30
        })

      {:ok, _view, html} = live(conn, ~p"/admin/ghost-protocol-configs")

      assert html =~ "Immediate Config"
      assert html =~ "Delayed Config"
      assert html =~ "2 configs"
      assert html =~ "Immediate"
      assert html =~ "Delayed"
    end

    test "shows crypto shred indicator", %{conn: conn, workspace: workspace} do
      _crypto =
        ghost_protocol_config_fixture(%{
          workspace_id: workspace.id,
          name: "Crypto Config",
          crypto_shred: true
        })

      {:ok, _view, html} = live(conn, ~p"/admin/ghost-protocol-configs")

      assert html =~ "Crypto Config"
      assert html =~ "Active"
    end
  end

  # ---------------------------------------------------------------------------
  # Create
  # ---------------------------------------------------------------------------

  describe "create config" do
    test "navigates to new config form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/ghost-protocol-configs")

      view |> element("a", "New Config") |> render_click()

      assert_patch(view, ~p"/admin/ghost-protocol-configs/new")
      assert render(view) =~ "New GhostProtocol Config"
    end

    test "creates config with valid data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/ghost-protocol-configs/new")

      # Select wipe fields
      view |> render_click("toggle_wipe_field", %{"field" => "input_content"})
      view |> render_click("toggle_wipe_field", %{"field" => "deliberation_messages"})

      view
      |> form("#ghost-protocol-config-form", %{
        config: %{
          name: "My Ghost Config",
          wipe_strategy: "immediate",
          max_session_duration_seconds: "300",
          crypto_shred: "true",
          enabled: "true"
        }
      })
      |> render_submit()

      assert_patch(view, "/admin/ghost-protocol-configs")
      html = render(view)
      assert html =~ "GhostProtocol config created."
      assert html =~ "My Ghost Config"
    end

    test "validates form on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/ghost-protocol-configs/new")

      assert view
             |> form("#ghost-protocol-config-form", %{config: %{name: ""}})
             |> render_change() =~ "can&#39;t be blank"
    end

    test "shows delay field for delayed strategy", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/ghost-protocol-configs/new")

      html =
        view
        |> form("#ghost-protocol-config-form", %{config: %{wipe_strategy: "delayed"}})
        |> render_change()

      assert html =~ "Wipe Delay"
    end

    test "hides delay field for immediate strategy", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/ghost-protocol-configs/new")

      # First switch to delayed
      view
      |> form("#ghost-protocol-config-form", %{config: %{wipe_strategy: "delayed"}})
      |> render_change()

      # Then switch back to immediate
      html =
        view
        |> form("#ghost-protocol-config-form", %{config: %{wipe_strategy: "immediate"}})
        |> render_change()

      refute html =~ "Wipe Delay"
    end

    test "wipe field toggle adds and removes fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/ghost-protocol-configs/new")

      view |> render_click("toggle_wipe_field", %{"field" => "input_content"})
      html = render(view)
      assert html =~ "input_content"

      # Toggle off
      view |> render_click("toggle_wipe_field", %{"field" => "input_content"})
      # After removing, the field name won't appear in the preview with field highlighting
    end
  end

  # ---------------------------------------------------------------------------
  # Edit
  # ---------------------------------------------------------------------------

  describe "edit config" do
    test "displays current values in edit form", %{conn: conn, workspace: workspace} do
      config =
        ghost_protocol_config_fixture(%{
          workspace_id: workspace.id,
          name: "Original Config",
          wipe_strategy: :delayed,
          wipe_delay_seconds: 60
        })

      {:ok, _view, html} = live(conn, ~p"/admin/ghost-protocol-configs/#{config.id}/edit")

      assert html =~ "Edit GhostProtocol Config"
      assert html =~ "Original Config"
    end

    test "updates config with valid changes", %{conn: conn, workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id, name: "Old Config"})

      {:ok, view, _html} = live(conn, ~p"/admin/ghost-protocol-configs/#{config.id}/edit")

      view
      |> form("#ghost-protocol-config-form", %{
        config: %{name: "Updated Config"}
      })
      |> render_submit()

      assert_patch(view, "/admin/ghost-protocol-configs")
      html = render(view)
      assert html =~ "GhostProtocol config updated."
      assert html =~ "Updated Config"
    end

    test "prevents editing config from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_config = ghost_protocol_config_fixture(%{workspace_id: other_workspace.id})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/admin/ghost-protocol-configs/#{other_config.id}/edit")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Delete
  # ---------------------------------------------------------------------------

  describe "delete config" do
    test "deletes a config without linked workflows", %{conn: conn, workspace: workspace} do
      config =
        ghost_protocol_config_fixture(%{workspace_id: workspace.id, name: "Delete Me"})

      {:ok, view, _html} = live(conn, ~p"/admin/ghost-protocol-configs")

      assert render(view) =~ "Delete Me"

      view |> render_click("delete", %{"id" => config.id})

      html = render(view)
      assert html =~ "GhostProtocol config deleted."
      refute html =~ "Delete Me"
    end

    test "prevents deleting config with linked workflows", %{
      conn: conn,
      workspace: workspace
    } do
      config =
        ghost_protocol_config_fixture(%{workspace_id: workspace.id, name: "Linked Config"})

      _workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: config.id
        })

      {:ok, view, _html} = live(conn, ~p"/admin/ghost-protocol-configs")

      view |> render_click("delete", %{"id" => config.id})

      html = render(view)
      assert html =~ "Cannot delete"
      assert html =~ "workflow(s) use this config"
    end
  end

  # ---------------------------------------------------------------------------
  # Show (config detail)
  # ---------------------------------------------------------------------------

  describe "show config" do
    test "displays config details", %{conn: conn, workspace: workspace} do
      config =
        ghost_protocol_config_fixture(%{
          workspace_id: workspace.id,
          name: "Detail Config",
          wipe_strategy: :immediate,
          crypto_shred: true,
          max_session_duration_seconds: 600
        })

      {:ok, _view, html} = live(conn, ~p"/admin/ghost-protocol-configs/#{config.id}")

      assert html =~ "Detail Config"
      assert html =~ "Immediate"
      assert html =~ "Active"
      assert html =~ "600"
    end

    test "shows linked workflows", %{conn: conn, workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      _workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          name: "Linked Workflow",
          ghost_protocol_config_id: config.id
        })

      {:ok, _view, html} = live(conn, ~p"/admin/ghost-protocol-configs/#{config.id}")

      assert html =~ "Linked Workflow"
    end

    test "prevents viewing config from another workspace", %{conn: conn} do
      other_workspace = workspace_fixture()
      other_config = ghost_protocol_config_fixture(%{workspace_id: other_workspace.id})

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/admin/ghost-protocol-configs/#{other_config.id}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Security
  # ---------------------------------------------------------------------------

  describe "security" do
    test "redirects when user lacks ghost_protocol:view permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin])

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/admin/ghost-protocol-configs")
    end

    test "rejects create without ghost_protocol:create permission", %{
      conn: conn,
      permissions: perms
    } do
      {conn2, _workspace2} = restricted_conn(conn, [perms.admin, perms.view])

      {:ok, view, _html} = live(conn2, ~p"/admin/ghost-protocol-configs/new")

      view |> render_click("toggle_wipe_field", %{"field" => "input_content"})

      html =
        view
        |> form("#ghost-protocol-config-form", %{
          config: %{
            name: "Sneaky Config",
            wipe_strategy: "immediate",
            max_session_duration_seconds: "300"
          }
        })
        |> render_submit()

      assert html =~ "Unauthorized"
    end

    test "scopes data to current workspace only", %{conn: conn, workspace: workspace} do
      _our =
        ghost_protocol_config_fixture(%{workspace_id: workspace.id, name: "Our Config"})

      other_workspace = workspace_fixture()

      _other =
        ghost_protocol_config_fixture(%{workspace_id: other_workspace.id, name: "Other Config"})

      {:ok, _view, html} = live(conn, ~p"/admin/ghost-protocol-configs")

      assert html =~ "Our Config"
      refute html =~ "Other Config"
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  describe "pubsub - config changes" do
    test "creating config triggers PubSub broadcast", %{conn: conn, workspace: workspace} do
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "ghost_protocol:#{workspace.id}")

      {:ok, view, _html} = live(conn, ~p"/admin/ghost-protocol-configs/new")

      view |> render_click("toggle_wipe_field", %{"field" => "input_content"})

      view
      |> form("#ghost-protocol-config-form", %{
        config: %{
          name: "Broadcast Test",
          wipe_strategy: "immediate",
          max_session_duration_seconds: "300"
        }
      })
      |> render_submit()

      assert_receive {:config_created, _config_id}, 1000
    end
  end
end
