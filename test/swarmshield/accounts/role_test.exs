defmodule Swarmshield.Accounts.RoleTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Accounts.Role
  alias Swarmshield.AccountsFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = AccountsFixtures.valid_role_attributes()
      changeset = Role.changeset(%Role{}, attrs)

      assert changeset.valid?
    end

    test "requires name" do
      attrs = AccountsFixtures.valid_role_attributes(%{name: nil})
      changeset = Role.changeset(%Role{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name format - lowercase and underscores only" do
      valid_names = ["admin", "super_admin", "a1", "role_123", "viewer"]

      invalid_names = [
        "Admin",
        "super admin",
        "UPPERCASE",
        "_starts_underscore",
        "123starts_number",
        "special!char",
        "has-hyphen"
      ]

      for name <- valid_names do
        attrs = AccountsFixtures.valid_role_attributes(%{name: name})
        changeset = Role.changeset(%Role{}, attrs)
        assert changeset.valid?, "Expected name '#{name}' to be valid"
      end

      for name <- invalid_names do
        attrs = AccountsFixtures.valid_role_attributes(%{name: name})
        changeset = Role.changeset(%Role{}, attrs)
        refute changeset.valid?, "Expected name '#{name}' to be invalid"
        assert %{name: [_msg]} = errors_on(changeset)
      end
    end

    test "name with spaces rejected" do
      attrs = AccountsFixtures.valid_role_attributes(%{name: "has spaces"})
      changeset = Role.changeset(%Role{}, attrs)

      refute changeset.valid?
      assert %{name: [_msg]} = errors_on(changeset)
    end

    test "validates name max length" do
      long_name = String.duplicate("a", 101)
      attrs = AccountsFixtures.valid_role_attributes(%{name: long_name})
      changeset = Role.changeset(%Role{}, attrs)

      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 100"
    end

    test "validates description max length" do
      long_desc = String.duplicate("a", 501)
      attrs = AccountsFixtures.valid_role_attributes(%{description: long_desc})
      changeset = Role.changeset(%Role{}, attrs)

      refute changeset.valid?
      assert %{description: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 500"
    end

    test "duplicate role name returns changeset error" do
      role = AccountsFixtures.role_fixture(%{name: "unique_test"})

      attrs = AccountsFixtures.valid_role_attributes(%{name: role.name})
      changeset = Role.changeset(%Role{}, attrs)
      {:error, changeset} = Repo.insert(changeset)

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "changeset does NOT cast is_system" do
      attrs = AccountsFixtures.valid_role_attributes(%{is_system: true})
      changeset = Role.changeset(%Role{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :is_system) == false
    end

    test "is_system defaults to false" do
      attrs = AccountsFixtures.valid_role_attributes()
      changeset = Role.changeset(%Role{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :is_system) == false
    end
  end

  describe "system_changeset/2" do
    test "allows setting is_system to true" do
      attrs = AccountsFixtures.valid_role_attributes(%{is_system: true})
      changeset = Role.system_changeset(%Role{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :is_system) == true
    end

    test "requires name" do
      changeset = Role.system_changeset(%Role{}, %{is_system: true})

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name format" do
      attrs = %{name: "Invalid Name", is_system: true}
      changeset = Role.system_changeset(%Role{}, attrs)

      refute changeset.valid?
      assert %{name: [_msg]} = errors_on(changeset)
    end
  end

  describe "role_fixture/1" do
    test "creates a role with default attributes" do
      role = AccountsFixtures.role_fixture()

      assert role.id
      assert role.name
      assert role.description == "A test role"
      assert role.is_system == false
    end

    test "creates a role with custom attributes" do
      role = AccountsFixtures.role_fixture(%{name: "custom_role", description: "Custom"})

      assert role.name == "custom_role"
      assert role.description == "Custom"
    end
  end

  describe "system_role_fixture/1" do
    test "creates a system role" do
      role = AccountsFixtures.system_role_fixture(%{name: "sys_role"})

      assert role.is_system == true
      assert role.name == "sys_role"
    end
  end

  describe "system roles protection" do
    test "system roles (is_system: true) have the flag persisted" do
      role = AccountsFixtures.system_role_fixture()

      reloaded = Repo.get!(Role, role.id)
      assert reloaded.is_system == true
    end
  end
end
