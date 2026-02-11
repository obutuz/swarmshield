defmodule Swarmshield.Accounts.WorkspaceContextTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Accounts
  alias Swarmshield.Accounts.UserWorkspaceRole
  alias Swarmshield.AccountsFixtures

  describe "list_workspaces/1" do
    test "returns paginated workspaces ordered by name" do
      w1 = AccountsFixtures.workspace_fixture(%{name: "Alpha", slug: "alpha"})
      w2 = AccountsFixtures.workspace_fixture(%{name: "Beta", slug: "beta"})
      _w3 = AccountsFixtures.workspace_fixture(%{name: "Gamma", slug: "gamma"})

      {workspaces, total_count} = Accounts.list_workspaces(page: 1, page_size: 2)

      assert total_count == 3
      assert length(workspaces) == 2
      assert hd(workspaces).id == w1.id
      assert List.last(workspaces).id == w2.id
    end

    test "returns all workspaces with default pagination" do
      for i <- 1..3, do: AccountsFixtures.workspace_fixture(%{slug: "ws-#{i}"})

      {workspaces, total_count} = Accounts.list_workspaces()

      assert total_count == 3
      assert length(workspaces) == 3
    end

    test "returns empty list when no workspaces exist" do
      {workspaces, total_count} = Accounts.list_workspaces()

      assert workspaces == []
      assert total_count == 0
    end

    test "second page returns remaining workspaces" do
      for i <- 1..5 do
        AccountsFixtures.workspace_fixture(%{
          name: "Workspace #{String.pad_leading("#{i}", 2, "0")}",
          slug: "ws-page-#{i}"
        })
      end

      {page2, total_count} = Accounts.list_workspaces(page: 2, page_size: 3)

      assert total_count == 5
      assert length(page2) == 2
    end
  end

  describe "get_workspace!/1" do
    test "returns workspace by id" do
      workspace = AccountsFixtures.workspace_fixture()
      found = Accounts.get_workspace!(workspace.id)

      assert found.id == workspace.id
      assert found.name == workspace.name
    end

    test "raises Ecto.NoResultsError for missing id" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_workspace!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_workspace/1" do
    test "creates workspace with valid attributes" do
      attrs = AccountsFixtures.valid_workspace_attributes()
      {:ok, workspace} = Accounts.create_workspace(attrs)

      assert workspace.id
      assert workspace.name == attrs.name
      assert workspace.slug == attrs.slug
    end

    test "creates audit entry on workspace creation" do
      attrs = AccountsFixtures.valid_workspace_attributes()
      {:ok, workspace} = Accounts.create_workspace(attrs)

      entry =
        Repo.one(
          from(a in Swarmshield.Accounts.AuditEntry,
            where: a.action == "workspace.create" and a.resource_id == ^workspace.id
          )
        )

      assert entry
      assert entry.resource_type == "workspace"
    end

    test "returns error for invalid attributes" do
      assert {:error, changeset} = Accounts.create_workspace(%{name: ""})
      assert %{name: _} = errors_on(changeset)
    end

    test "returns error for duplicate slug" do
      attrs = AccountsFixtures.valid_workspace_attributes()
      {:ok, _} = Accounts.create_workspace(attrs)

      assert {:error, changeset} = Accounts.create_workspace(attrs)
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "update_workspace/2" do
    test "updates workspace with valid attributes" do
      workspace = AccountsFixtures.workspace_fixture()
      {:ok, updated} = Accounts.update_workspace(workspace, %{name: "Updated Name"})

      assert updated.name == "Updated Name"
      assert updated.slug == workspace.slug
    end

    test "creates audit entry on workspace update" do
      workspace = AccountsFixtures.workspace_fixture()
      {:ok, _updated} = Accounts.update_workspace(workspace, %{name: "New Name"})

      entry =
        Repo.one(
          from(a in Swarmshield.Accounts.AuditEntry,
            where: a.action == "workspace.update" and a.resource_id == ^workspace.id
          )
        )

      assert entry
      assert entry.workspace_id == workspace.id
    end

    test "returns error for invalid attributes" do
      workspace = AccountsFixtures.workspace_fixture()
      assert {:error, changeset} = Accounts.update_workspace(workspace, %{name: ""})
      assert %{name: _} = errors_on(changeset)
    end
  end

  describe "delete_workspace/1" do
    test "deletes a workspace" do
      workspace = AccountsFixtures.workspace_fixture()
      {:ok, deleted} = Accounts.delete_workspace(workspace)

      assert deleted.id == workspace.id

      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_workspace!(workspace.id)
      end
    end

    test "creates audit entry on workspace deletion" do
      workspace = AccountsFixtures.workspace_fixture()
      workspace_id = workspace.id
      {:ok, _} = Accounts.delete_workspace(workspace)

      entry =
        Repo.one(
          from(a in Swarmshield.Accounts.AuditEntry,
            where: a.action == "workspace.delete" and a.resource_id == ^workspace_id
          )
        )

      assert entry
      assert entry.resource_type == "workspace"
    end
  end

  describe "get_workspace_by_api_key/1" do
    test "returns workspace when api key matches" do
      workspace = AccountsFixtures.workspace_fixture()
      {:ok, {raw_key, _updated}} = Accounts.generate_workspace_api_key(workspace)

      found = Accounts.get_workspace_by_api_key(raw_key)
      assert found.id == workspace.id
    end

    test "returns nil for unknown api key" do
      assert Accounts.get_workspace_by_api_key("swrm_unknown_key_12345") == nil
    end

    test "returns nil for nil input" do
      assert Accounts.get_workspace_by_api_key(nil) == nil
    end
  end

  describe "generate_workspace_api_key/1" do
    test "generates a cryptographically secure api key" do
      workspace = AccountsFixtures.workspace_fixture()
      {:ok, {raw_key, updated}} = Accounts.generate_workspace_api_key(workspace)

      assert String.starts_with?(raw_key, "swrm_")
      assert byte_size(raw_key) > 20
      assert updated.api_key_hash
      assert updated.api_key_prefix == String.slice(raw_key, 0, 8)
    end

    test "different invocations produce different keys" do
      workspace = AccountsFixtures.workspace_fixture()
      {:ok, {key1, _}} = Accounts.generate_workspace_api_key(workspace)

      workspace = Accounts.get_workspace!(workspace.id)
      {:ok, {key2, _}} = Accounts.generate_workspace_api_key(workspace)

      refute key1 == key2
    end

    test "creates audit entry on api key generation" do
      workspace = AccountsFixtures.workspace_fixture()
      {:ok, {_raw_key, _updated}} = Accounts.generate_workspace_api_key(workspace)

      entry =
        Repo.one(
          from(a in Swarmshield.Accounts.AuditEntry,
            where: a.action == "workspace.api_key_generated" and a.resource_id == ^workspace.id
          )
        )

      assert entry
      assert entry.metadata["prefix"]
    end

    test "old api key no longer works after regeneration" do
      workspace = AccountsFixtures.workspace_fixture()
      {:ok, {old_key, _}} = Accounts.generate_workspace_api_key(workspace)

      workspace = Accounts.get_workspace!(workspace.id)
      {:ok, {_new_key, _}} = Accounts.generate_workspace_api_key(workspace)

      assert Accounts.get_workspace_by_api_key(old_key) == nil
    end
  end

  describe "assign_user_to_workspace/3" do
    setup do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()
      role = AccountsFixtures.role_fixture()
      %{user: user, workspace: workspace, role: role}
    end

    test "assigns user to workspace with role", %{
      user: user,
      workspace: workspace,
      role: role
    } do
      {:ok, uwr} = Accounts.assign_user_to_workspace(user, workspace, role)

      assert uwr.user_id == user.id
      assert uwr.workspace_id == workspace.id
      assert uwr.role_id == role.id
    end

    test "replaces existing role via upsert (no duplicate)", %{
      user: user,
      workspace: workspace,
      role: role
    } do
      {:ok, _uwr1} = Accounts.assign_user_to_workspace(user, workspace, role)

      new_role = AccountsFixtures.role_fixture(%{name: "new_role"})
      {:ok, uwr2} = Accounts.assign_user_to_workspace(user, workspace, new_role)

      assert uwr2.role_id == new_role.id

      # Verify only one record exists
      count =
        Repo.aggregate(
          from(u in UserWorkspaceRole,
            where: u.user_id == ^user.id and u.workspace_id == ^workspace.id
          ),
          :count
        )

      assert count == 1
    end

    test "creates audit entry on assignment", %{user: user, workspace: workspace, role: role} do
      {:ok, _uwr} = Accounts.assign_user_to_workspace(user, workspace, role)

      entry =
        Repo.one(
          from(a in Swarmshield.Accounts.AuditEntry,
            where: a.action == "workspace.user_assigned" and a.workspace_id == ^workspace.id
          )
        )

      assert entry
      assert entry.metadata["role_name"] == role.name
    end
  end

  describe "remove_user_from_workspace/2" do
    test "removes user from workspace" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()
      role = AccountsFixtures.role_fixture()
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)

      assert :ok = Accounts.remove_user_from_workspace(user, workspace)

      assert Accounts.get_user_workspace_role(user, workspace) == nil
    end

    test "is idempotent - no error if user is not a member" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()

      assert :ok = Accounts.remove_user_from_workspace(user, workspace)
    end

    test "creates audit entry when user was actually removed" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()
      role = AccountsFixtures.role_fixture()
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)

      :ok = Accounts.remove_user_from_workspace(user, workspace)

      entry =
        Repo.one(
          from(a in Swarmshield.Accounts.AuditEntry,
            where: a.action == "workspace.user_removed" and a.workspace_id == ^workspace.id
          )
        )

      assert entry
    end

    test "does not create audit entry when user was not a member" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()

      :ok = Accounts.remove_user_from_workspace(user, workspace)

      entry =
        Repo.one(
          from(a in Swarmshield.Accounts.AuditEntry,
            where: a.action == "workspace.user_removed" and a.workspace_id == ^workspace.id
          )
        )

      assert entry == nil
    end
  end

  describe "get_user_workspace_role/2" do
    test "returns user workspace role with role preloaded" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()
      role = AccountsFixtures.role_fixture()
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)

      uwr = Accounts.get_user_workspace_role(user, workspace)

      assert uwr.user_id == user.id
      assert uwr.workspace_id == workspace.id
      assert uwr.role.name == role.name
    end

    test "returns nil if user is not a member" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()

      assert Accounts.get_user_workspace_role(user, workspace) == nil
    end
  end

  describe "list_user_workspaces/2" do
    test "returns workspaces with roles for user" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()
      role = AccountsFixtures.role_fixture()
      {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)

      {results, total_count} = Accounts.list_user_workspaces(user)

      assert total_count == 1
      assert length(results) == 1

      result = hd(results)
      assert result.workspace.id == workspace.id
      assert result.role.name == role.name
    end

    test "returns empty list for user with no workspaces" do
      user = AccountsFixtures.user_fixture()

      {results, total_count} = Accounts.list_user_workspaces(user)

      assert results == []
      assert total_count == 0
    end

    test "paginates results" do
      user = AccountsFixtures.user_fixture()
      role = AccountsFixtures.role_fixture()

      for i <- 1..5 do
        workspace =
          AccountsFixtures.workspace_fixture(%{
            name: "WS #{String.pad_leading("#{i}", 2, "0")}",
            slug: "ws-list-#{i}"
          })

        {:ok, _} = Accounts.assign_user_to_workspace(user, workspace, role)
      end

      {page1, total_count} = Accounts.list_user_workspaces(user, page: 1, page_size: 3)
      {page2, _} = Accounts.list_user_workspaces(user, page: 2, page_size: 3)

      assert total_count == 5
      assert length(page1) == 3
      assert length(page2) == 2
    end

    test "orders by workspace name" do
      user = AccountsFixtures.user_fixture()
      role = AccountsFixtures.role_fixture()

      ws_b = AccountsFixtures.workspace_fixture(%{name: "Bravo", slug: "bravo-ws"})
      ws_a = AccountsFixtures.workspace_fixture(%{name: "Alpha", slug: "alpha-ws"})

      {:ok, _} = Accounts.assign_user_to_workspace(user, ws_b, role)
      {:ok, _} = Accounts.assign_user_to_workspace(user, ws_a, role)

      {results, _} = Accounts.list_user_workspaces(user)

      assert hd(results).workspace.id == ws_a.id
      assert List.last(results).workspace.id == ws_b.id
    end

    test "does not return other users' workspaces" do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()
      role = AccountsFixtures.role_fixture()

      {:ok, _} = Accounts.assign_user_to_workspace(user1, workspace, role)

      {results, total_count} = Accounts.list_user_workspaces(user2)

      assert results == []
      assert total_count == 0
    end
  end
end
