defmodule Swarmshield.Accounts.UserWorkspaceRoleTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Accounts.UserWorkspaceRole
  alias Swarmshield.AccountsFixtures

  defp create_user_workspace_role(_context) do
    user = AccountsFixtures.user_fixture()
    workspace = AccountsFixtures.workspace_fixture()
    role = AccountsFixtures.role_fixture()
    %{user: user, workspace: workspace, role: role}
  end

  describe "changeset/2" do
    setup :create_user_workspace_role

    test "valid attributes produce a valid changeset", %{
      user: user,
      workspace: workspace,
      role: role
    } do
      changeset =
        UserWorkspaceRole.changeset(%UserWorkspaceRole{}, %{
          user_id: user.id,
          workspace_id: workspace.id,
          role_id: role.id
        })

      assert changeset.valid?
    end

    test "requires user_id", %{workspace: workspace, role: role} do
      changeset =
        UserWorkspaceRole.changeset(%UserWorkspaceRole{}, %{
          workspace_id: workspace.id,
          role_id: role.id
        })

      refute changeset.valid?
      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires workspace_id", %{user: user, role: role} do
      changeset =
        UserWorkspaceRole.changeset(%UserWorkspaceRole{}, %{
          user_id: user.id,
          role_id: role.id
        })

      refute changeset.valid?
      assert %{workspace_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires role_id", %{user: user, workspace: workspace} do
      changeset =
        UserWorkspaceRole.changeset(%UserWorkspaceRole{}, %{
          user_id: user.id,
          workspace_id: workspace.id
        })

      refute changeset.valid?
      assert %{role_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "unique constraint on user_id + workspace_id (one role per user per workspace)", %{
      user: user,
      workspace: workspace,
      role: role
    } do
      AccountsFixtures.user_workspace_role_fixture(user, workspace, role)

      role2 = AccountsFixtures.role_fixture()

      changeset =
        UserWorkspaceRole.changeset(%UserWorkspaceRole{}, %{
          user_id: user.id,
          workspace_id: workspace.id,
          role_id: role2.id
        })

      {:error, changeset} = Repo.insert(changeset)
      assert %{user_id: ["user already has a role in this workspace"]} = errors_on(changeset)
    end

    test "same user can have roles in different workspaces", %{user: user, role: role} do
      workspace1 = AccountsFixtures.workspace_fixture()
      workspace2 = AccountsFixtures.workspace_fixture()

      uwr1 = AccountsFixtures.user_workspace_role_fixture(user, workspace1, role)
      uwr2 = AccountsFixtures.user_workspace_role_fixture(user, workspace2, role)

      assert uwr1.id
      assert uwr2.id
      assert uwr1.id != uwr2.id
    end

    test "different users can have roles in same workspace", %{workspace: workspace, role: role} do
      user1 = AccountsFixtures.user_fixture()
      user2 = AccountsFixtures.user_fixture()

      uwr1 = AccountsFixtures.user_workspace_role_fixture(user1, workspace, role)
      uwr2 = AccountsFixtures.user_workspace_role_fixture(user2, workspace, role)

      assert uwr1.id
      assert uwr2.id
    end

    test "foreign key constraint on user_id", %{workspace: workspace, role: role} do
      fake_id = Ecto.UUID.generate()

      changeset =
        UserWorkspaceRole.changeset(%UserWorkspaceRole{}, %{
          user_id: fake_id,
          workspace_id: workspace.id,
          role_id: role.id
        })

      {:error, changeset} = Repo.insert(changeset)
      assert %{user_id: ["does not exist"]} = errors_on(changeset)
    end

    test "foreign key constraint on workspace_id", %{user: user, role: role} do
      fake_id = Ecto.UUID.generate()

      changeset =
        UserWorkspaceRole.changeset(%UserWorkspaceRole{}, %{
          user_id: user.id,
          workspace_id: fake_id,
          role_id: role.id
        })

      {:error, changeset} = Repo.insert(changeset)
      assert %{workspace_id: ["does not exist"]} = errors_on(changeset)
    end

    test "foreign key constraint on role_id", %{user: user, workspace: workspace} do
      fake_id = Ecto.UUID.generate()

      changeset =
        UserWorkspaceRole.changeset(%UserWorkspaceRole{}, %{
          user_id: user.id,
          workspace_id: workspace.id,
          role_id: fake_id
        })

      {:error, changeset} = Repo.insert(changeset)
      assert %{role_id: ["does not exist"]} = errors_on(changeset)
    end
  end

  describe "user_workspace_role_fixture/3" do
    test "creates a user-workspace-role assignment" do
      user = AccountsFixtures.user_fixture()
      workspace = AccountsFixtures.workspace_fixture()
      role = AccountsFixtures.role_fixture()

      uwr = AccountsFixtures.user_workspace_role_fixture(user, workspace, role)

      assert uwr.id
      assert uwr.user_id == user.id
      assert uwr.workspace_id == workspace.id
      assert uwr.role_id == role.id
    end
  end
end
