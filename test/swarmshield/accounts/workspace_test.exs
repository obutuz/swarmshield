defmodule Swarmshield.Accounts.WorkspaceTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Accounts.Workspace
  alias Swarmshield.AccountsFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = AccountsFixtures.valid_workspace_attributes()
      changeset = Workspace.changeset(%Workspace{}, attrs)

      assert changeset.valid?
    end

    test "requires name" do
      attrs = AccountsFixtures.valid_workspace_attributes(%{name: nil})
      changeset = Workspace.changeset(%Workspace{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires slug" do
      attrs = AccountsFixtures.valid_workspace_attributes(%{slug: nil})
      changeset = Workspace.changeset(%Workspace{}, attrs)

      refute changeset.valid?
      assert %{slug: ["can't be blank"]} = errors_on(changeset)
    end

    test "cannot be created with empty name" do
      attrs = AccountsFixtures.valid_workspace_attributes(%{name: ""})
      changeset = Workspace.changeset(%Workspace{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name max length" do
      long_name = String.duplicate("a", 256)
      attrs = AccountsFixtures.valid_workspace_attributes(%{name: long_name})
      changeset = Workspace.changeset(%Workspace{}, attrs)

      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "validates slug format - lowercase and hyphens only" do
      valid_slugs = ["my-workspace", "test", "a", "workspace-123", "a1"]

      invalid_slugs = [
        "My-Workspace",
        "test space",
        "-starts-hyphen",
        "ends-hyphen-",
        "UPPERCASE",
        "special!char"
      ]

      for slug <- valid_slugs do
        attrs = AccountsFixtures.valid_workspace_attributes(%{slug: slug})
        changeset = Workspace.changeset(%Workspace{}, attrs)
        assert changeset.valid?, "Expected slug '#{slug}' to be valid"
      end

      for slug <- invalid_slugs do
        attrs = AccountsFixtures.valid_workspace_attributes(%{slug: slug})
        changeset = Workspace.changeset(%Workspace{}, attrs)
        refute changeset.valid?, "Expected slug '#{slug}' to be invalid"
        assert %{slug: [_msg]} = errors_on(changeset)
      end
    end

    test "validates description max length" do
      long_desc = String.duplicate("a", 1001)
      attrs = AccountsFixtures.valid_workspace_attributes(%{description: long_desc})
      changeset = Workspace.changeset(%Workspace{}, attrs)

      refute changeset.valid?
      assert %{description: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 1000"
    end

    test "same slug rejected (globally unique constraint)" do
      workspace = AccountsFixtures.workspace_fixture(%{slug: "unique-test"})

      attrs = AccountsFixtures.valid_workspace_attributes(%{slug: workspace.slug})
      changeset = Workspace.changeset(%Workspace{}, attrs)
      {:error, changeset} = Repo.insert(changeset)

      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "status defaults to :active" do
      attrs = AccountsFixtures.valid_workspace_attributes()
      changeset = Workspace.changeset(%Workspace{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :status) == :active
    end

    test "status transitions active -> suspended -> archived" do
      workspace = AccountsFixtures.workspace_fixture()
      assert workspace.status == :active

      {:ok, suspended} =
        workspace
        |> Workspace.changeset(%{status: :suspended})
        |> Repo.update()

      assert suspended.status == :suspended

      {:ok, archived} =
        suspended
        |> Workspace.changeset(%{status: :archived})
        |> Repo.update()

      assert archived.status == :archived
    end

    test "rejects invalid status values" do
      attrs = AccountsFixtures.valid_workspace_attributes(%{status: :invalid})
      changeset = Workspace.changeset(%Workspace{}, attrs)

      refute changeset.valid?
      assert %{status: [_msg]} = errors_on(changeset)
    end

    test "settings defaults to empty map" do
      attrs = AccountsFixtures.valid_workspace_attributes()
      changeset = Workspace.changeset(%Workspace{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :settings) == %{}
    end

    test "settings can store arbitrary map data" do
      settings = %{"max_agents" => 100, "features" => %{"deliberation" => true}}
      attrs = AccountsFixtures.valid_workspace_attributes(%{settings: settings})

      {:ok, workspace} =
        %Workspace{}
        |> Workspace.changeset(attrs)
        |> Repo.insert()

      assert workspace.settings == settings
    end

    test "changeset does NOT cast api_key_hash" do
      attrs =
        AccountsFixtures.valid_workspace_attributes(%{
          api_key_hash: "should_be_ignored"
        })

      changeset = Workspace.changeset(%Workspace{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :api_key_hash) == nil
    end

    test "changeset does NOT cast api_key_prefix" do
      attrs =
        AccountsFixtures.valid_workspace_attributes(%{
          api_key_prefix: "should_be_ignored"
        })

      changeset = Workspace.changeset(%Workspace{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :api_key_prefix) == nil
    end
  end

  describe "api_key_changeset/2" do
    test "sets api_key_hash and api_key_prefix" do
      workspace = AccountsFixtures.workspace_fixture()

      changeset =
        Workspace.api_key_changeset(workspace, %{
          api_key_hash: "hashed_key_value",
          api_key_prefix: "swrm_abc"
        })

      assert changeset.valid?
    end

    test "requires api_key_hash" do
      workspace = AccountsFixtures.workspace_fixture()
      changeset = Workspace.api_key_changeset(workspace, %{api_key_prefix: "swrm_abc"})

      refute changeset.valid?
      assert %{api_key_hash: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires api_key_prefix" do
      workspace = AccountsFixtures.workspace_fixture()
      changeset = Workspace.api_key_changeset(workspace, %{api_key_hash: "hashed_key_value"})

      refute changeset.valid?
      assert %{api_key_prefix: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "workspace_fixture/1" do
    test "creates a workspace with default attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      assert workspace.id
      assert workspace.name
      assert workspace.slug
      assert workspace.status == :active
      assert workspace.settings == %{}
    end

    test "creates a workspace with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture(%{name: "Custom", slug: "custom-ws"})

      assert workspace.name == "Custom"
      assert workspace.slug == "custom-ws"
    end
  end
end
