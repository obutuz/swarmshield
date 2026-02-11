defmodule Swarmshield.WorkflowsTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Deliberation.{ConsensusPolicy, Workflow, WorkflowStep}
  alias Swarmshield.Workflows

  import Swarmshield.AccountsFixtures, only: [workspace_fixture: 0]
  import Swarmshield.DeliberationFixtures
  import Swarmshield.GhostProtocolFixtures

  # ---------------------------------------------------------------------------
  # Workflow CRUD
  # ---------------------------------------------------------------------------

  describe "list_workflows/2" do
    test "returns paginated workflows for workspace" do
      workspace = workspace_fixture()

      w1 = workflow_fixture(%{workspace_id: workspace.id, name: "First"})
      w2 = workflow_fixture(%{workspace_id: workspace.id, name: "Second"})

      {workflows, total} = Workflows.list_workflows(workspace.id)

      assert total == 2
      assert length(workflows) == 2
      returned_ids = Enum.map(workflows, & &1.id)
      assert w1.id in returned_ids
      assert w2.id in returned_ids
    end

    test "preloads workflow_steps and ghost_protocol_config" do
      workspace = workspace_fixture()
      gpc = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      workflow =
        workflow_fixture(%{workspace_id: workspace.id, ghost_protocol_config_id: gpc.id})

      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      workflow_step_fixture(%{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        agent_definition_id: agent_def.id,
        position: 1
      })

      {[loaded], 1} = Workflows.list_workflows(workspace.id)

      assert loaded.ghost_protocol_config.id == gpc.id
      assert length(loaded.workflow_steps) == 1
    end

    test "respects pagination" do
      workspace = workspace_fixture()

      for _ <- 1..3, do: workflow_fixture(%{workspace_id: workspace.id})

      {workflows, total} = Workflows.list_workflows(workspace.id, page: 1, page_size: 2)

      assert total == 3
      assert length(workflows) == 2
    end

    test "workspace isolation" do
      workspace_a = workspace_fixture()
      workspace_b = workspace_fixture()

      workflow_fixture(%{workspace_id: workspace_a.id})
      workflow_fixture(%{workspace_id: workspace_b.id})

      {workflows_a, 1} = Workflows.list_workflows(workspace_a.id)
      {workflows_b, 1} = Workflows.list_workflows(workspace_b.id)

      assert hd(workflows_a).workspace_id == workspace_a.id
      assert hd(workflows_b).workspace_id == workspace_b.id
    end
  end

  describe "get_workflow!/1" do
    test "returns workflow with preloaded associations" do
      workspace = workspace_fixture()
      gpc = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      workflow =
        workflow_fixture(%{workspace_id: workspace.id, ghost_protocol_config_id: gpc.id})

      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      workflow_step_fixture(%{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        agent_definition_id: agent_def.id,
        position: 1
      })

      loaded = Workflows.get_workflow!(workflow.id)

      assert loaded.id == workflow.id
      assert loaded.ghost_protocol_config.id == gpc.id
      assert [step] = loaded.workflow_steps
      assert step.agent_definition.id == agent_def.id
    end

    test "raises for nonexistent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_workflow!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_workflow/2" do
    test "creates workflow with workspace_id set server-side" do
      workspace = workspace_fixture()

      attrs = %{
        name: "New Workflow",
        trigger_on: :flagged,
        timeout_seconds: 300,
        max_retries: 2
      }

      assert {:ok, %Workflow{} = workflow} = Workflows.create_workflow(workspace.id, attrs)
      assert workflow.workspace_id == workspace.id
      assert workflow.name == "New Workflow"
      assert workflow.trigger_on == :flagged
    end

    test "associates ghost_protocol_config_id" do
      workspace = workspace_fixture()
      gpc = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      attrs = %{
        name: "Ghost Workflow",
        trigger_on: :manual,
        ghost_protocol_config_id: gpc.id
      }

      assert {:ok, workflow} = Workflows.create_workflow(workspace.id, attrs)
      assert workflow.ghost_protocol_config_id == gpc.id
    end

    test "returns error changeset on invalid attrs" do
      workspace = workspace_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Workflows.create_workflow(workspace.id, %{name: nil})
    end
  end

  describe "update_workflow/2" do
    test "updates workflow attributes" do
      workspace = workspace_fixture()
      workflow = workflow_fixture(%{workspace_id: workspace.id})

      assert {:ok, updated} = Workflows.update_workflow(workflow, %{name: "Renamed"})
      assert updated.name == "Renamed"
    end

    test "returns error changeset on invalid update" do
      workspace = workspace_fixture()
      workflow = workflow_fixture(%{workspace_id: workspace.id})

      assert {:error, %Ecto.Changeset{}} =
               Workflows.update_workflow(workflow, %{timeout_seconds: -1})
    end
  end

  describe "delete_workflow/1" do
    test "deletes the workflow" do
      workspace = workspace_fixture()
      workflow = workflow_fixture(%{workspace_id: workspace.id})

      assert {:ok, %Workflow{}} = Workflows.delete_workflow(workflow)

      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_workflow!(workflow.id)
      end
    end
  end

  describe "get_enabled_workflow_for_trigger/2" do
    test "returns matching enabled workflow" do
      workspace = workspace_fixture()

      workflow =
        workflow_fixture(%{workspace_id: workspace.id, trigger_on: :flagged, enabled: true})

      found = Workflows.get_enabled_workflow_for_trigger(workspace.id, :flagged)
      assert found.id == workflow.id
    end

    test "returns nil when no match" do
      workspace = workspace_fixture()
      workflow_fixture(%{workspace_id: workspace.id, trigger_on: :blocked, enabled: true})

      assert is_nil(Workflows.get_enabled_workflow_for_trigger(workspace.id, :flagged))
    end

    test ":all trigger matches any event type" do
      workspace = workspace_fixture()
      workflow = workflow_fixture(%{workspace_id: workspace.id, trigger_on: :all, enabled: true})

      found = Workflows.get_enabled_workflow_for_trigger(workspace.id, :flagged)
      assert found.id == workflow.id

      found_blocked = Workflows.get_enabled_workflow_for_trigger(workspace.id, :blocked)
      assert found_blocked.id == workflow.id
    end

    test "disabled workflow is not returned" do
      workspace = workspace_fixture()

      workflow_fixture(%{workspace_id: workspace.id, trigger_on: :flagged, enabled: false})

      assert is_nil(Workflows.get_enabled_workflow_for_trigger(workspace.id, :flagged))
    end

    test "does not return workflows from other workspaces" do
      workspace_a = workspace_fixture()
      workspace_b = workspace_fixture()

      workflow_fixture(%{workspace_id: workspace_b.id, trigger_on: :flagged, enabled: true})

      assert is_nil(Workflows.get_enabled_workflow_for_trigger(workspace_a.id, :flagged))
    end
  end

  # ---------------------------------------------------------------------------
  # WorkflowStep CRUD
  # ---------------------------------------------------------------------------

  describe "list_workflow_steps/1" do
    test "returns steps ordered by position" do
      workspace = workspace_fixture()
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      s2 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          position: 2,
          name: "Step 2"
        })

      s1 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          position: 1,
          name: "Step 1"
        })

      steps = Workflows.list_workflow_steps(workflow.id)

      assert [first, second] = steps
      assert first.id == s1.id
      assert second.id == s2.id
    end
  end

  describe "create_workflow_step/1" do
    test "creates a step with required associations" do
      workspace = workspace_fixture()
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      attrs = %{
        workflow_id: workflow.id,
        agent_definition_id: agent_def.id,
        position: 1,
        name: "Analyzer Step"
      }

      assert {:ok, %WorkflowStep{} = step} = Workflows.create_workflow_step(attrs)
      assert step.workflow_id == workflow.id
      assert step.agent_definition_id == agent_def.id
      assert step.position == 1
    end

    test "returns error on missing required fields" do
      assert {:error, %Ecto.Changeset{}} = Workflows.create_workflow_step(%{})
    end
  end

  describe "update_workflow_step/2" do
    test "updates step attributes" do
      workspace = workspace_fixture()

      step =
        workflow_step_fixture(%{workspace_id: workspace.id, name: "Old Name", position: 1})

      assert {:ok, updated} = Workflows.update_workflow_step(step, %{name: "New Name"})
      assert updated.name == "New Name"
    end
  end

  describe "delete_workflow_step/1" do
    test "deletes the step" do
      workspace = workspace_fixture()
      step = workflow_step_fixture(%{workspace_id: workspace.id, position: 1})

      assert {:ok, %WorkflowStep{}} = Workflows.delete_workflow_step(step)

      assert Workflows.list_workflow_steps(step.workflow_id) == []
    end
  end

  describe "reorder_workflow_steps/2" do
    test "atomically reorders steps" do
      workspace = workspace_fixture()
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      s1 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          position: 1,
          name: "Step A"
        })

      s2 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          position: 2,
          name: "Step B"
        })

      s3 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          position: 3,
          name: "Step C"
        })

      assert {:ok, steps} =
               Workflows.reorder_workflow_steps(workflow.id, [s3.id, s1.id, s2.id])

      assert [first, second, third] = steps
      assert first.id == s3.id
      assert first.position == 1
      assert second.id == s1.id
      assert second.position == 2
      assert third.id == s2.id
      assert third.position == 3
    end

    test "returns error when IDs do not match workflow steps" do
      workspace = workspace_fixture()
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      s1 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          position: 1
        })

      bogus_id = Ecto.UUID.generate()

      assert {:error, :ids_mismatch} =
               Workflows.reorder_workflow_steps(workflow.id, [s1.id, bogus_id])
    end

    test "returns error when subset of IDs provided" do
      workspace = workspace_fixture()
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

      s1 =
        workflow_step_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_definition_id: agent_def.id,
          position: 1
        })

      workflow_step_fixture(%{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        agent_definition_id: agent_def.id,
        position: 2
      })

      assert {:error, :ids_mismatch} =
               Workflows.reorder_workflow_steps(workflow.id, [s1.id])
    end
  end

  # ---------------------------------------------------------------------------
  # ConsensusPolicy CRUD
  # ---------------------------------------------------------------------------

  describe "list_consensus_policies/2" do
    test "returns paginated policies for workspace" do
      workspace = workspace_fixture()

      p1 = consensus_policy_fixture(%{workspace_id: workspace.id})
      p2 = consensus_policy_fixture(%{workspace_id: workspace.id})

      {policies, total} = Workflows.list_consensus_policies(workspace.id)

      assert total == 2
      returned_ids = Enum.map(policies, & &1.id)
      assert p1.id in returned_ids
      assert p2.id in returned_ids
    end

    test "workspace isolation for policies" do
      workspace_a = workspace_fixture()
      workspace_b = workspace_fixture()

      consensus_policy_fixture(%{workspace_id: workspace_a.id})
      consensus_policy_fixture(%{workspace_id: workspace_b.id})

      {policies_a, 1} = Workflows.list_consensus_policies(workspace_a.id)
      assert hd(policies_a).workspace_id == workspace_a.id

      {policies_b, 1} = Workflows.list_consensus_policies(workspace_b.id)
      assert hd(policies_b).workspace_id == workspace_b.id
    end
  end

  describe "get_consensus_policy!/1" do
    test "returns the policy" do
      workspace = workspace_fixture()
      policy = consensus_policy_fixture(%{workspace_id: workspace.id})

      loaded = Workflows.get_consensus_policy!(policy.id)
      assert loaded.id == policy.id
    end

    test "raises for nonexistent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_consensus_policy!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_consensus_policy/2" do
    test "creates policy with workspace_id set server-side" do
      workspace = workspace_fixture()

      attrs = %{
        name: "Majority Policy",
        strategy: :majority,
        threshold: 0.5
      }

      assert {:ok, %ConsensusPolicy{} = policy} =
               Workflows.create_consensus_policy(workspace.id, attrs)

      assert policy.workspace_id == workspace.id
      assert policy.name == "Majority Policy"
      assert policy.strategy == :majority
    end

    test "returns error on invalid attrs" do
      workspace = workspace_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Workflows.create_consensus_policy(workspace.id, %{name: nil})
    end
  end

  describe "update_consensus_policy/2" do
    test "updates policy attributes" do
      workspace = workspace_fixture()
      policy = consensus_policy_fixture(%{workspace_id: workspace.id})

      assert {:ok, updated} =
               Workflows.update_consensus_policy(policy, %{name: "Updated Policy"})

      assert updated.name == "Updated Policy"
    end
  end

  describe "delete_consensus_policy/1" do
    test "deletes the policy" do
      workspace = workspace_fixture()
      policy = consensus_policy_fixture(%{workspace_id: workspace.id})

      assert {:ok, %ConsensusPolicy{}} = Workflows.delete_consensus_policy(policy)

      assert_raise Ecto.NoResultsError, fn ->
        Workflows.get_consensus_policy!(policy.id)
      end
    end
  end
end
