defmodule Swarmshield.Accounts.RolePermissionTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Accounts.RolePermission
  alias Swarmshield.AccountsFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      role = AccountsFixtures.role_fixture()
      permission = AccountsFixtures.permission_fixture()

      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_id: role.id,
          permission_id: permission.id
        })

      assert changeset.valid?
    end

    test "requires role_id" do
      permission = AccountsFixtures.permission_fixture()

      changeset =
        RolePermission.changeset(%RolePermission{}, %{permission_id: permission.id})

      refute changeset.valid?
      assert %{role_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires permission_id" do
      role = AccountsFixtures.role_fixture()

      changeset =
        RolePermission.changeset(%RolePermission{}, %{role_id: role.id})

      refute changeset.valid?
      assert %{permission_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "unique constraint on role_id + permission_id" do
      role = AccountsFixtures.role_fixture()
      permission = AccountsFixtures.permission_fixture()

      AccountsFixtures.role_permission_fixture(role, permission)

      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_id: role.id,
          permission_id: permission.id
        })

      {:error, changeset} = Repo.insert(changeset)
      assert %{role_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "same role can have multiple different permissions" do
      role = AccountsFixtures.role_fixture()
      perm1 = AccountsFixtures.permission_fixture(%{resource: "agents", action: "view"})
      perm2 = AccountsFixtures.permission_fixture(%{resource: "agents", action: "create"})

      rp1 = AccountsFixtures.role_permission_fixture(role, perm1)
      rp2 = AccountsFixtures.role_permission_fixture(role, perm2)

      assert rp1.id
      assert rp2.id
      assert rp1.id != rp2.id
    end

    test "same permission can belong to multiple roles" do
      role1 = AccountsFixtures.role_fixture()
      role2 = AccountsFixtures.role_fixture()
      perm = AccountsFixtures.permission_fixture()

      rp1 = AccountsFixtures.role_permission_fixture(role1, perm)
      rp2 = AccountsFixtures.role_permission_fixture(role2, perm)

      assert rp1.id
      assert rp2.id
      assert rp1.id != rp2.id
    end

    test "foreign key constraint on role_id" do
      permission = AccountsFixtures.permission_fixture()
      fake_id = Ecto.UUID.generate()

      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_id: fake_id,
          permission_id: permission.id
        })

      {:error, changeset} = Repo.insert(changeset)
      assert %{role_id: ["does not exist"]} = errors_on(changeset)
    end

    test "foreign key constraint on permission_id" do
      role = AccountsFixtures.role_fixture()
      fake_id = Ecto.UUID.generate()

      changeset =
        RolePermission.changeset(%RolePermission{}, %{
          role_id: role.id,
          permission_id: fake_id
        })

      {:error, changeset} = Repo.insert(changeset)
      assert %{permission_id: ["does not exist"]} = errors_on(changeset)
    end
  end

  describe "role_permission_fixture/2" do
    test "creates a role-permission association" do
      role = AccountsFixtures.role_fixture()
      permission = AccountsFixtures.permission_fixture()
      rp = AccountsFixtures.role_permission_fixture(role, permission)

      assert rp.id
      assert rp.role_id == role.id
      assert rp.permission_id == permission.id
    end
  end
end
