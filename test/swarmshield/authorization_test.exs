defmodule Swarmshield.AuthorizationTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Accounts
  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Authorization
  alias Swarmshield.Authorization.AuthCache

  setup do
    user = AccountsFixtures.user_fixture()
    workspace = AccountsFixtures.workspace_fixture()
    role = AccountsFixtures.role_fixture(%{name: "test_role"})
    permission = AccountsFixtures.permission_fixture(%{resource: "dashboard", action: "view"})

    # Create additional permissions NOT assigned to the role
    # This prevents the :all marker from being triggered (role doesn't have all perms)
    AccountsFixtures.permission_fixture(%{resource: "agents", action: "delete"})
    AccountsFixtures.permission_fixture(%{resource: "policies", action: "create"})

    AccountsFixtures.role_permission_fixture(role, permission)
    {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)

    %{
      user: user,
      workspace: workspace,
      role: role,
      permission: permission,
      permission_key: "dashboard:view"
    }
  end

  describe "has_permission?/3" do
    test "returns true when user has the permission", ctx do
      assert Authorization.has_permission?(ctx.user, ctx.workspace, ctx.permission_key)
    end

    test "returns false when user does not have the permission", ctx do
      refute Authorization.has_permission?(ctx.user, ctx.workspace, "agents:delete")
    end

    test "returns false for nil user", ctx do
      refute Authorization.has_permission?(nil, ctx.workspace, ctx.permission_key)
    end

    test "returns false for nil workspace", ctx do
      refute Authorization.has_permission?(ctx.user, nil, ctx.permission_key)
    end

    test "returns false for user with no workspace role" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()

      refute Authorization.has_permission?(user, workspace, "dashboard:view")
    end

    test "returns false for suspended workspace", ctx do
      {:ok, suspended} =
        Accounts.update_workspace(ctx.workspace, %{status: :suspended})

      # Invalidate cache so it reloads with new workspace status
      Authorization.invalidate_user_permissions(ctx.user.id, suspended.id)

      refute Authorization.has_permission?(ctx.user, suspended, ctx.permission_key)
    end

    test "returns false for archived workspace", ctx do
      {:ok, archived} =
        Accounts.update_workspace(ctx.workspace, %{status: :archived})

      Authorization.invalidate_user_permissions(ctx.user.id, archived.id)

      refute Authorization.has_permission?(ctx.user, archived, ctx.permission_key)
    end
  end

  describe "has_role?/3" do
    test "returns true when user has the role", ctx do
      assert Authorization.has_role?(ctx.user, ctx.workspace, "test_role")
    end

    test "returns false when user does not have the role", ctx do
      refute Authorization.has_role?(ctx.user, ctx.workspace, "nonexistent_role")
    end

    test "returns false for nil user", ctx do
      refute Authorization.has_role?(nil, ctx.workspace, "test_role")
    end

    test "returns false for nil workspace", ctx do
      refute Authorization.has_role?(ctx.user, nil, "test_role")
    end
  end

  describe "has_any_permission?/3" do
    test "returns true if any permission matches", ctx do
      assert Authorization.has_any_permission?(ctx.user, ctx.workspace, [
               "agents:delete",
               ctx.permission_key
             ])
    end

    test "returns false if no permission matches", ctx do
      refute Authorization.has_any_permission?(ctx.user, ctx.workspace, [
               "agents:delete",
               "policies:create"
             ])
    end

    test "returns false for empty permission list", ctx do
      refute Authorization.has_any_permission?(ctx.user, ctx.workspace, [])
    end

    test "returns false for nil user", ctx do
      refute Authorization.has_any_permission?(nil, ctx.workspace, [ctx.permission_key])
    end
  end

  describe "authorize!/3" do
    test "returns :ok when authorized", ctx do
      assert :ok = Authorization.authorize!(ctx.user, ctx.workspace, ctx.permission_key)
    end

    test "raises UnauthorizedError when not authorized", ctx do
      assert_raise Swarmshield.UnauthorizedError, fn ->
        Authorization.authorize!(ctx.user, ctx.workspace, "agents:delete")
      end
    end

    test "raises UnauthorizedError with permission info", ctx do
      error =
        assert_raise Swarmshield.UnauthorizedError, fn ->
          Authorization.authorize!(ctx.user, ctx.workspace, "agents:delete")
        end

      assert error.permission == "agents:delete"
      assert error.message =~ "agents:delete"
    end

    test "raises UnauthorizedError for nil user", ctx do
      assert_raise Swarmshield.UnauthorizedError, fn ->
        Authorization.authorize!(nil, ctx.workspace, ctx.permission_key)
      end
    end

    test "raises UnauthorizedError for nil workspace", ctx do
      assert_raise Swarmshield.UnauthorizedError, fn ->
        Authorization.authorize!(ctx.user, nil, ctx.permission_key)
      end
    end
  end

  describe "cache behavior" do
    test "caches permissions on first access", ctx do
      # First call loads from DB and caches
      assert Authorization.has_permission?(ctx.user, ctx.workspace, ctx.permission_key)

      # Verify it's in the cache
      assert {:ok, _permissions} =
               AuthCache.get_permissions(ctx.user.id, ctx.workspace.id)
    end

    test "cache miss triggers database load", ctx do
      # Ensure cache is empty for this user
      AuthCache.invalidate(ctx.user.id, ctx.workspace.id)

      # Should still work (loads from DB)
      assert Authorization.has_permission?(ctx.user, ctx.workspace, ctx.permission_key)
    end

    test "invalidation removes cache entry", ctx do
      # Populate cache
      Authorization.has_permission?(ctx.user, ctx.workspace, ctx.permission_key)

      # Invalidate
      Authorization.invalidate_user_permissions(ctx.user.id, ctx.workspace.id)

      # Should be a miss now
      assert :miss = AuthCache.get_permissions(ctx.user.id, ctx.workspace.id)
    end

    test "workspace invalidation removes all entries for workspace", ctx do
      user2 = AccountsFixtures.user_fixture()
      {:ok, _} = Accounts.assign_user_to_workspace(user2, ctx.workspace, ctx.role)

      # Populate cache for both users
      Authorization.has_permission?(ctx.user, ctx.workspace, ctx.permission_key)
      Authorization.has_permission?(user2, ctx.workspace, ctx.permission_key)

      # Invalidate entire workspace
      Authorization.invalidate_workspace_permissions(ctx.workspace.id)

      # Both should be cache misses now
      assert :miss = AuthCache.get_permissions(ctx.user.id, ctx.workspace.id)
      assert :miss = AuthCache.get_permissions(user2.id, ctx.workspace.id)
    end

    test "role assignment change triggers cache invalidation", ctx do
      # Populate cache
      Authorization.has_permission?(ctx.user, ctx.workspace, ctx.permission_key)
      assert {:ok, _} = AuthCache.get_permissions(ctx.user.id, ctx.workspace.id)

      # Change role assignment
      new_role = AccountsFixtures.role_fixture(%{name: "new_test_role"})
      {:ok, _} = Accounts.assign_user_to_workspace(ctx.user, ctx.workspace, new_role)

      # Cache should be invalidated (PubSub is async, give it a moment)
      Process.sleep(50)

      assert :miss = AuthCache.get_permissions(ctx.user.id, ctx.workspace.id)
    end

    test "user removal triggers cache invalidation", ctx do
      # Populate cache
      Authorization.has_permission?(ctx.user, ctx.workspace, ctx.permission_key)
      assert {:ok, _} = AuthCache.get_permissions(ctx.user.id, ctx.workspace.id)

      # Remove user
      :ok = Accounts.remove_user_from_workspace(ctx.user, ctx.workspace)

      # Cache should be invalidated
      Process.sleep(50)

      assert :miss = AuthCache.get_permissions(ctx.user.id, ctx.workspace.id)
    end
  end

  describe "super_admin :all marker" do
    test "user with all permissions gets :all marker cached" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()
      role = AccountsFixtures.role_fixture(%{name: "all_perms_role"})

      # Get all existing permissions in the database
      all_permissions = Repo.all(Swarmshield.Accounts.Permission)

      # Assign ALL permissions to the role
      Enum.each(all_permissions, fn perm ->
        AccountsFixtures.role_permission_fixture(role, perm)
      end)

      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)

      # Check permission - should return true
      perm_key =
        "#{hd(all_permissions).resource}:#{hd(all_permissions).action}"

      assert Authorization.has_permission?(user, workspace, perm_key)

      # Verify :all marker in cache
      {:ok, cached} = AuthCache.get_permissions(user.id, workspace.id)
      assert cached == :all
    end

    test ":all marker grants access to any permission" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()

      # Manually cache :all marker
      AuthCache.put_permissions(user.id, workspace.id, :all)

      assert Authorization.has_permission?(user, workspace, "anything:at_all")
      assert Authorization.has_permission?(user, workspace, "nonexistent:permission")
    end
  end

  describe "ETS resilience" do
    test "handles ETS table not available gracefully" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()

      # Direct ETS operations should rescue gracefully
      assert :miss = AuthCache.get_permissions("nonexistent_user", "nonexistent_ws")
      assert :ok = AuthCache.put_permissions(user.id, workspace.id, MapSet.new())
      assert :ok = AuthCache.invalidate(user.id, workspace.id)
      assert :ok = AuthCache.invalidate_workspace(workspace.id)
    end
  end
end
