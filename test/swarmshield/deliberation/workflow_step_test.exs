defmodule Swarmshield.Deliberation.WorkflowStepTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Deliberation.WorkflowStep
  alias Swarmshield.DeliberationFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      workspace = AccountsFixtures.workspace_fixture()
      workflow = DeliberationFixtures.workflow_fixture(%{workspace_id: workspace.id})
      definition = DeliberationFixtures.agent_definition_fixture(%{workspace_id: workspace.id})

      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          workflow_id: workflow.id,
          agent_definition_id: definition.id
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      assert changeset.valid?
    end

    test "requires position" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          position: nil,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      refute changeset.valid?
      assert %{position: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires name" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          name: nil,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires workflow_id" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      refute changeset.valid?
      assert %{workflow_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires agent_definition_id" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          workflow_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      refute changeset.valid?
      assert %{agent_definition_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name max length" do
      long_name = String.duplicate("a", 256)

      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          name: long_name,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "accepts all valid execution_modes" do
      for mode <- [:sequential, :parallel] do
        attrs =
          DeliberationFixtures.valid_workflow_step_attributes(%{
            execution_mode: mode,
            workflow_id: Ecto.UUID.generate(),
            agent_definition_id: Ecto.UUID.generate()
          })

        changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

        assert changeset.valid?, "Expected execution_mode #{mode} to be valid"
      end
    end

    test "rejects invalid execution_mode" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          execution_mode: :invalid,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      refute changeset.valid?
      assert %{execution_mode: [_msg]} = errors_on(changeset)
    end

    test "execution_mode defaults to :sequential" do
      changeset = WorkflowStep.changeset(%WorkflowStep{}, %{})
      assert Ecto.Changeset.get_field(changeset, :execution_mode) == :sequential
    end

    test "config defaults to empty map" do
      changeset = WorkflowStep.changeset(%WorkflowStep{}, %{})
      assert Ecto.Changeset.get_field(changeset, :config) == %{}
    end

    test "nil prompt_template_id is valid" do
      workspace = AccountsFixtures.workspace_fixture()
      workflow = DeliberationFixtures.workflow_fixture(%{workspace_id: workspace.id})
      definition = DeliberationFixtures.agent_definition_fixture(%{workspace_id: workspace.id})

      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          workflow_id: workflow.id,
          agent_definition_id: definition.id,
          prompt_template_id: nil
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      assert changeset.valid?
    end
  end

  describe "position validation" do
    test "position 0 is rejected (must be >= 1)" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          position: 0,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      refute changeset.valid?
      assert %{position: [msg]} = errors_on(changeset)
      assert msg =~ "greater than or equal to 1"
    end

    test "position 1 is valid (minimum)" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          position: 1,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      assert changeset.valid?
    end

    test "duplicate position within same workflow is rejected" do
      workspace = AccountsFixtures.workspace_fixture()
      workflow = DeliberationFixtures.workflow_fixture(%{workspace_id: workspace.id})
      definition = DeliberationFixtures.agent_definition_fixture(%{workspace_id: workspace.id})

      _step1 =
        DeliberationFixtures.workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: definition.id,
          position: 1
        })

      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          position: 1,
          workflow_id: workflow.id,
          agent_definition_id: definition.id
        })

      {:error, changeset} =
        %WorkflowStep{}
        |> WorkflowStep.changeset(attrs)
        |> Repo.insert()

      assert %{workflow_id: [msg]} = errors_on(changeset)
      assert msg =~ "position already taken"
    end

    test "same position allowed in different workflows" do
      workspace = AccountsFixtures.workspace_fixture()
      workflow1 = DeliberationFixtures.workflow_fixture(%{workspace_id: workspace.id})
      workflow2 = DeliberationFixtures.workflow_fixture(%{workspace_id: workspace.id})
      definition = DeliberationFixtures.agent_definition_fixture(%{workspace_id: workspace.id})

      _step1 =
        DeliberationFixtures.workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow1.id,
          agent_definition_id: definition.id,
          position: 1
        })

      step2 =
        DeliberationFixtures.workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow2.id,
          agent_definition_id: definition.id,
          position: 1
        })

      assert step2.position == 1
    end
  end

  describe "timeout and retry validation" do
    test "timeout_seconds 10 is valid (minimum)" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          timeout_seconds: 10,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      assert changeset.valid?
    end

    test "timeout_seconds 9 is rejected" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          timeout_seconds: 9,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      refute changeset.valid?
      assert %{timeout_seconds: [msg]} = errors_on(changeset)
      assert msg =~ "greater than or equal to 10"
    end

    test "timeout_seconds 3600 is valid (maximum)" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          timeout_seconds: 3600,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      assert changeset.valid?
    end

    test "timeout_seconds 3601 is rejected" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          timeout_seconds: 3601,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      refute changeset.valid?
      assert %{timeout_seconds: [msg]} = errors_on(changeset)
      assert msg =~ "less than or equal to 3600"
    end

    test "retry_count 0 is valid" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          retry_count: 0,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      assert changeset.valid?
    end

    test "retry_count 5 is valid (maximum)" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          retry_count: 5,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      assert changeset.valid?
    end

    test "retry_count 6 is rejected" do
      attrs =
        DeliberationFixtures.valid_workflow_step_attributes(%{
          retry_count: 6,
          workflow_id: Ecto.UUID.generate(),
          agent_definition_id: Ecto.UUID.generate()
        })

      changeset = WorkflowStep.changeset(%WorkflowStep{}, attrs)

      refute changeset.valid?
      assert %{retry_count: [msg]} = errors_on(changeset)
      assert msg =~ "less than or equal to 5"
    end
  end

  describe "fixture and database persistence" do
    test "creates a workflow step with default attributes" do
      step = DeliberationFixtures.workflow_step_fixture()

      assert step.id
      assert step.workflow_id
      assert step.agent_definition_id
      assert step.position == 1
      assert step.execution_mode == :sequential
      assert step.timeout_seconds == 120
      assert step.retry_count == 1
      assert step.config == %{}
    end

    test "creates a workflow step with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()
      workflow = DeliberationFixtures.workflow_fixture(%{workspace_id: workspace.id})
      definition = DeliberationFixtures.agent_definition_fixture(%{workspace_id: workspace.id})

      step =
        DeliberationFixtures.workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: definition.id,
          position: 3,
          execution_mode: :parallel,
          timeout_seconds: 60
        })

      assert step.position == 3
      assert step.execution_mode == :parallel
      assert step.timeout_seconds == 60
    end

    test "reloaded step matches inserted data" do
      step = DeliberationFixtures.workflow_step_fixture()
      reloaded = Repo.get!(WorkflowStep, step.id)

      assert reloaded.position == step.position
      assert reloaded.name == step.name
      assert reloaded.workflow_id == step.workflow_id
    end
  end
end
