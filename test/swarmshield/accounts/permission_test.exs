defmodule Swarmshield.Accounts.PermissionTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Accounts.Permission
  alias Swarmshield.AccountsFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = AccountsFixtures.valid_permission_attributes()
      changeset = Permission.changeset(%Permission{}, attrs)

      assert changeset.valid?
    end

    test "requires resource" do
      attrs = AccountsFixtures.valid_permission_attributes(%{resource: nil})
      changeset = Permission.changeset(%Permission{}, attrs)

      refute changeset.valid?
      assert %{resource: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires action" do
      attrs = AccountsFixtures.valid_permission_attributes(%{action: nil})
      changeset = Permission.changeset(%Permission{}, attrs)

      refute changeset.valid?
      assert %{action: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates resource format" do
      invalid_resources = ["Dashboard", "UPPER", "has-hyphen", "123start", "has space"]

      for resource <- invalid_resources do
        attrs = AccountsFixtures.valid_permission_attributes(%{resource: resource})
        changeset = Permission.changeset(%Permission{}, attrs)
        refute changeset.valid?, "Expected resource '#{resource}' to be invalid"
      end
    end

    test "validates action format" do
      invalid_actions = ["View", "UPPER", "has-hyphen", "123start"]

      for action <- invalid_actions do
        attrs = AccountsFixtures.valid_permission_attributes(%{action: action})
        changeset = Permission.changeset(%Permission{}, attrs)
        refute changeset.valid?, "Expected action '#{action}' to be invalid"
      end
    end

    test "unique constraint on resource + action combination" do
      perm = AccountsFixtures.permission_fixture(%{resource: "dashboard", action: "view"})

      attrs = %{resource: perm.resource, action: perm.action}
      changeset = Permission.changeset(%Permission{}, attrs)
      {:error, changeset} = Repo.insert(changeset)

      assert %{resource: ["has already been taken"]} = errors_on(changeset)
    end

    test "same resource with different action is allowed" do
      AccountsFixtures.permission_fixture(%{resource: "dashboard", action: "view"})
      perm2 = AccountsFixtures.permission_fixture(%{resource: "dashboard", action: "export"})

      assert perm2.id
    end

    test "validates description max length" do
      long_desc = String.duplicate("a", 501)
      attrs = AccountsFixtures.valid_permission_attributes(%{description: long_desc})
      changeset = Permission.changeset(%Permission{}, attrs)

      refute changeset.valid?
      assert %{description: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 500"
    end
  end

  describe "key/1" do
    test "returns resource:action string" do
      perm = %Permission{resource: "dashboard", action: "view"}
      assert Permission.key(perm) == "dashboard:view"
    end

    test "works with different resources and actions" do
      perm = %Permission{resource: "agents", action: "create"}
      assert Permission.key(perm) == "agents:create"
    end
  end

  describe "permission_fixture/1" do
    test "creates a permission with default attributes" do
      perm = AccountsFixtures.permission_fixture()

      assert perm.id
      assert perm.resource
      assert perm.action == "view"
    end

    test "creates a permission with custom attributes" do
      perm = AccountsFixtures.permission_fixture(%{resource: "agents", action: "delete"})

      assert perm.resource == "agents"
      assert perm.action == "delete"
    end
  end
end
