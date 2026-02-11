defmodule Swarmshield.Deliberation.WorkflowTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Deliberation.Workflow
  alias Swarmshield.DeliberationFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = DeliberationFixtures.valid_workflow_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      changeset = Workflow.changeset(%Workflow{workspace_id: workspace.id}, attrs)

      assert changeset.valid?
    end

    test "requires name" do
      attrs = DeliberationFixtures.valid_workflow_attributes(%{name: nil})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires trigger_on" do
      attrs = DeliberationFixtures.valid_workflow_attributes(%{trigger_on: nil})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      refute changeset.valid?
      assert %{trigger_on: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name max length" do
      long_name = String.duplicate("a", 256)
      attrs = DeliberationFixtures.valid_workflow_attributes(%{name: long_name})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "validates description max length" do
      long_desc = String.duplicate("a", 2001)
      attrs = DeliberationFixtures.valid_workflow_attributes(%{description: long_desc})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      refute changeset.valid?
      assert %{description: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 2000"
    end

    test "accepts all valid trigger_on types" do
      for trigger <- [:flagged, :blocked, :manual, :all] do
        attrs = DeliberationFixtures.valid_workflow_attributes(%{trigger_on: trigger})
        changeset = Workflow.changeset(%Workflow{}, attrs)

        assert changeset.valid?, "Expected trigger_on #{trigger} to be valid"
      end
    end

    test "rejects invalid trigger_on" do
      attrs = DeliberationFixtures.valid_workflow_attributes(%{trigger_on: :invalid})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      refute changeset.valid?
      assert %{trigger_on: [_msg]} = errors_on(changeset)
    end

    test "enabled defaults to true" do
      changeset = Workflow.changeset(%Workflow{}, %{})
      assert Ecto.Changeset.get_field(changeset, :enabled) == true
    end

    test "trigger_on defaults to :flagged" do
      attrs = DeliberationFixtures.valid_workflow_attributes()
      changeset = Workflow.changeset(%Workflow{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :trigger_on) == :flagged
    end

    test "workflow with no steps is valid" do
      attrs = DeliberationFixtures.valid_workflow_attributes()
      workspace = AccountsFixtures.workspace_fixture()

      {:ok, workflow} =
        %Workflow{workspace_id: workspace.id}
        |> Workflow.changeset(attrs)
        |> Repo.insert()

      assert workflow.id
      loaded = Repo.preload(workflow, :workflow_steps)
      assert loaded.workflow_steps == []
    end
  end

  describe "timeout_seconds validation" do
    test "timeout_seconds exactly 30 is valid (minimum)" do
      attrs = DeliberationFixtures.valid_workflow_attributes(%{timeout_seconds: 30})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      assert changeset.valid?
    end

    test "timeout_seconds exactly 3600 is valid (maximum)" do
      attrs = DeliberationFixtures.valid_workflow_attributes(%{timeout_seconds: 3600})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      assert changeset.valid?
    end

    test "timeout_seconds 29 is rejected" do
      attrs = DeliberationFixtures.valid_workflow_attributes(%{timeout_seconds: 29})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      refute changeset.valid?
      assert %{timeout_seconds: [msg]} = errors_on(changeset)
      assert msg =~ "greater than or equal to 30"
    end

    test "timeout_seconds 3601 is rejected" do
      attrs = DeliberationFixtures.valid_workflow_attributes(%{timeout_seconds: 3601})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      refute changeset.valid?
      assert %{timeout_seconds: [msg]} = errors_on(changeset)
      assert msg =~ "less than or equal to 3600"
    end

    test "timeout_seconds defaults to 300" do
      attrs = DeliberationFixtures.valid_workflow_attributes()
      changeset = Workflow.changeset(%Workflow{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :timeout_seconds) == 300
    end
  end

  describe "max_retries validation" do
    test "max_retries 0 is valid" do
      attrs = DeliberationFixtures.valid_workflow_attributes(%{max_retries: 0})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      assert changeset.valid?
    end

    test "max_retries 10 is valid (maximum)" do
      attrs = DeliberationFixtures.valid_workflow_attributes(%{max_retries: 10})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      assert changeset.valid?
    end

    test "max_retries 11 is rejected" do
      attrs = DeliberationFixtures.valid_workflow_attributes(%{max_retries: 11})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      refute changeset.valid?
      assert %{max_retries: [msg]} = errors_on(changeset)
      assert msg =~ "less than or equal to 10"
    end

    test "max_retries -1 is rejected" do
      attrs = DeliberationFixtures.valid_workflow_attributes(%{max_retries: -1})
      changeset = Workflow.changeset(%Workflow{}, attrs)

      refute changeset.valid?
      assert %{max_retries: [msg]} = errors_on(changeset)
      assert msg =~ "greater than or equal to 0"
    end

    test "max_retries defaults to 2" do
      attrs = DeliberationFixtures.valid_workflow_attributes()
      changeset = Workflow.changeset(%Workflow{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :max_retries) == 2
    end
  end

  describe "fixture and database persistence" do
    test "creates a workflow with default attributes" do
      workflow = DeliberationFixtures.workflow_fixture()

      assert workflow.id
      assert workflow.workspace_id
      assert workflow.name
      assert workflow.trigger_on == :flagged
      assert workflow.enabled == true
      assert workflow.timeout_seconds == 300
      assert workflow.max_retries == 2
    end

    test "creates a workflow with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      workflow =
        DeliberationFixtures.workflow_fixture(%{
          workspace_id: workspace.id,
          trigger_on: :blocked,
          timeout_seconds: 600,
          max_retries: 5
        })

      assert workflow.trigger_on == :blocked
      assert workflow.timeout_seconds == 600
      assert workflow.max_retries == 5
    end

    test "reloaded workflow matches inserted data" do
      workflow = DeliberationFixtures.workflow_fixture()
      reloaded = Repo.get!(Workflow, workflow.id)

      assert reloaded.name == workflow.name
      assert reloaded.trigger_on == workflow.trigger_on
      assert reloaded.timeout_seconds == workflow.timeout_seconds
    end
  end
end
