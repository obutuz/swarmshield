defmodule SwarmshieldWeb.Hooks.AuthHooksTest do
  use SwarmshieldWeb.ConnCase, async: false

  alias Phoenix.LiveView
  alias Swarmshield.Accounts
  alias Swarmshield.Accounts.Scope
  alias Swarmshield.Authorization
  alias SwarmshieldWeb.Hooks.AuthHooks

  import Swarmshield.AccountsFixtures

  defp build_socket(assigns \\ %{}) do
    %LiveView.Socket{
      endpoint: SwarmshieldWeb.Endpoint,
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)
    }
  end

  defp authenticated_session(user) do
    token = Accounts.generate_user_session_token(user)
    %{"user_token" => token}
  end

  describe "on_mount :ensure_authenticated" do
    test "continues with valid user session" do
      user = user_fixture()
      session = authenticated_session(user)

      {:cont, updated_socket} =
        AuthHooks.on_mount(:ensure_authenticated, %{}, session, build_socket())

      assert updated_socket.assigns.current_scope.user.id == user.id
    end

    test "redirects to login with invalid token" do
      session = %{"user_token" => "invalid_token"}

      {:halt, updated_socket} =
        AuthHooks.on_mount(:ensure_authenticated, %{}, session, build_socket())

      assert updated_socket.assigns.current_scope == nil
    end

    test "redirects to login with no token" do
      session = %{}

      {:halt, updated_socket} =
        AuthHooks.on_mount(:ensure_authenticated, %{}, session, build_socket())

      assert updated_socket.assigns.current_scope == nil
    end

    test "does not re-assign current_scope if already present" do
      user = user_fixture()
      scope = Scope.for_user(user)
      session = %{}
      socket = build_socket(%{current_scope: scope})

      {:cont, updated_socket} =
        AuthHooks.on_mount(:ensure_authenticated, %{}, session, socket)

      assert updated_socket.assigns.current_scope.user.id == user.id
    end
  end

  describe "on_mount :load_workspace" do
    setup do
      user = user_fixture()
      workspace = workspace_fixture()
      role = role_fixture(%{name: "test_role"})
      permission = permission_fixture(%{resource: "dashboard", action: "view"})

      # Add extra permissions so the :all marker isn't triggered
      permission_fixture(%{resource: "agents", action: "delete"})
      permission_fixture(%{resource: "policies", action: "create"})

      role_permission_fixture(role, permission)
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)

      scope = Scope.for_user(user)

      %{
        user: user,
        workspace: workspace,
        role: role,
        permission: permission,
        scope: scope
      }
    end

    test "loads workspace, role, and permissions", ctx do
      session =
        Map.merge(authenticated_session(ctx.user), %{
          "current_workspace_id" => ctx.workspace.id
        })

      socket = build_socket(%{current_scope: ctx.scope})

      {:cont, updated_socket} =
        AuthHooks.on_mount(:load_workspace, %{}, session, socket)

      assert updated_socket.assigns.current_workspace.id == ctx.workspace.id
      assert updated_socket.assigns.current_role.id == ctx.role.id

      assert is_map(updated_socket.assigns.user_permissions) or
               updated_socket.assigns.user_permissions == :all
    end

    test "assigns correct permissions as MapSet", ctx do
      session =
        Map.merge(authenticated_session(ctx.user), %{
          "current_workspace_id" => ctx.workspace.id
        })

      socket = build_socket(%{current_scope: ctx.scope})

      {:cont, updated_socket} =
        AuthHooks.on_mount(:load_workspace, %{}, session, socket)

      permissions = updated_socket.assigns.user_permissions
      assert MapSet.member?(permissions, "dashboard:view")
      refute MapSet.member?(permissions, "agents:delete")
    end

    test "redirects when no workspace_id in session", ctx do
      session = authenticated_session(ctx.user)
      socket = build_socket(%{current_scope: ctx.scope})

      {:halt, _updated_socket} =
        AuthHooks.on_mount(:load_workspace, %{}, session, socket)
    end

    test "redirects when workspace_id is empty string", ctx do
      session =
        Map.merge(authenticated_session(ctx.user), %{
          "current_workspace_id" => ""
        })

      socket = build_socket(%{current_scope: ctx.scope})

      {:halt, _updated_socket} =
        AuthHooks.on_mount(:load_workspace, %{}, session, socket)
    end

    test "redirects for invalid workspace_id format", ctx do
      session =
        Map.merge(authenticated_session(ctx.user), %{
          "current_workspace_id" => "not-a-uuid"
        })

      socket = build_socket(%{current_scope: ctx.scope})

      {:halt, _updated_socket} =
        AuthHooks.on_mount(:load_workspace, %{}, session, socket)
    end

    test "redirects for non-existent workspace_id", ctx do
      session =
        Map.merge(authenticated_session(ctx.user), %{
          "current_workspace_id" => Ecto.UUID.generate()
        })

      socket = build_socket(%{current_scope: ctx.scope})

      {:halt, _updated_socket} =
        AuthHooks.on_mount(:load_workspace, %{}, session, socket)
    end

    test "redirects with flash for suspended workspace", ctx do
      {:ok, suspended} = Accounts.update_workspace(ctx.workspace, %{status: :suspended})

      session =
        Map.merge(authenticated_session(ctx.user), %{
          "current_workspace_id" => suspended.id
        })

      socket = build_socket(%{current_scope: ctx.scope})

      {:halt, _updated_socket} =
        AuthHooks.on_mount(:load_workspace, %{}, session, socket)
    end

    test "redirects with flash for archived workspace", ctx do
      {:ok, archived} = Accounts.update_workspace(ctx.workspace, %{status: :archived})

      session =
        Map.merge(authenticated_session(ctx.user), %{
          "current_workspace_id" => archived.id
        })

      socket = build_socket(%{current_scope: ctx.scope})

      {:halt, _updated_socket} =
        AuthHooks.on_mount(:load_workspace, %{}, session, socket)
    end

    test "redirects for user not member of workspace", ctx do
      other_user = user_fixture()
      other_scope = Scope.for_user(other_user)

      session =
        Map.merge(authenticated_session(other_user), %{
          "current_workspace_id" => ctx.workspace.id
        })

      socket = build_socket(%{current_scope: other_scope})

      {:halt, _updated_socket} =
        AuthHooks.on_mount(:load_workspace, %{}, session, socket)
    end
  end

  describe "on_mount {:require_permission, key}" do
    setup do
      user = user_fixture()
      workspace = workspace_fixture()
      role = role_fixture(%{name: "perm_role"})
      permission = permission_fixture(%{resource: "dashboard", action: "view"})

      # Add extra permissions so the :all marker isn't triggered
      permission_fixture(%{resource: "agents", action: "delete"})
      permission_fixture(%{resource: "policies", action: "create"})

      role_permission_fixture(role, permission)
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)

      scope = Scope.for_user(user)
      permissions = Authorization.get_user_permissions(user.id, workspace.id)

      socket =
        build_socket(%{
          current_scope: scope,
          current_workspace: workspace,
          current_role: role,
          user_permissions: permissions
        })

      %{socket: socket, user: user, workspace: workspace}
    end

    test "continues when user has the required permission", ctx do
      {:cont, _socket} =
        AuthHooks.on_mount(
          {:require_permission, "dashboard:view"},
          %{},
          %{},
          ctx.socket
        )
    end

    test "halts when user lacks the required permission", ctx do
      {:halt, _socket} =
        AuthHooks.on_mount(
          {:require_permission, "agents:delete"},
          %{},
          %{},
          ctx.socket
        )
    end

    test "continues when user has :all permissions" do
      socket =
        build_socket(%{
          user_permissions: :all,
          current_scope: %Scope{user: %Accounts.User{}},
          current_workspace: %{},
          current_role: %{}
        })

      {:cont, _socket} =
        AuthHooks.on_mount(
          {:require_permission, "anything:at_all"},
          %{},
          %{},
          socket
        )
    end

    test "halts when user_permissions not assigned" do
      socket = build_socket(%{})

      {:halt, _socket} =
        AuthHooks.on_mount(
          {:require_permission, "dashboard:view"},
          %{},
          %{},
          socket
        )
    end
  end

  describe "has_socket_permission?/2" do
    test "returns true when permission exists in MapSet" do
      socket = build_socket(%{user_permissions: MapSet.new(["dashboard:view", "events:view"])})
      assert AuthHooks.has_socket_permission?(socket, "dashboard:view")
    end

    test "returns false when permission not in MapSet" do
      socket = build_socket(%{user_permissions: MapSet.new(["dashboard:view"])})
      refute AuthHooks.has_socket_permission?(socket, "agents:delete")
    end

    test "returns true for :all marker" do
      socket = build_socket(%{user_permissions: :all})
      assert AuthHooks.has_socket_permission?(socket, "anything:at_all")
    end

    test "returns false when user_permissions not assigned" do
      socket = build_socket(%{})
      refute AuthHooks.has_socket_permission?(socket, "dashboard:view")
    end
  end
end
