defmodule Swarmshield.Gateway.DeliberationTriggerTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Accounts.AuditEntry
  alias Swarmshield.Gateway
  alias Swarmshield.Repo

  import Ecto.Query
  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.PoliciesFixtures

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Swarmshield.TaskSupervisor),
          is_pid(pid) do
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          500 -> :ok
        end
      end
    end)

    workspace = workspace_fixture()
    agent = registered_agent_fixture(%{workspace_id: workspace.id})
    %{workspace: workspace, agent: agent}
  end

  describe "auto-trigger deliberation on flagged events" do
    test "triggers deliberation when matching workflow exists", %{
      workspace: workspace,
      agent: agent
    } do
      workflow = workflow_fixture(%{workspace_id: workspace.id, trigger_on: :flagged})

      rule = create_flag_rule(workspace)
      insert_rules_into_cache(workspace.id, [rule])

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberations:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :tool_call,
          content: "Suspicious API call"
        })

      {:ok, evaluated} = Gateway.evaluate_event(event, workspace.id)
      assert evaluated.status == :flagged

      assert_receive {:trigger_deliberation, event_id, received_workflow}, 2000
      assert event_id == event.id
      assert received_workflow.id == workflow.id
    end

    test "no deliberation triggered for allowed events", %{
      workspace: workspace,
      agent: agent
    } do
      _workflow = workflow_fixture(%{workspace_id: workspace.id, trigger_on: :flagged})

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberations:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "Safe action"
        })

      {:ok, evaluated} = Gateway.evaluate_event(event, workspace.id)
      assert evaluated.status == :allowed

      refute_receive {:trigger_deliberation, _, _}, 500
    end

    test "no deliberation triggered for blocked events", %{
      workspace: workspace,
      agent: agent
    } do
      _workflow = workflow_fixture(%{workspace_id: workspace.id, trigger_on: :flagged})

      rule = create_block_rule(workspace)
      insert_rules_into_cache(workspace.id, [rule])

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberations:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :error,
          content: "Blocked event"
        })

      {:ok, evaluated} = Gateway.evaluate_event(event, workspace.id)
      assert evaluated.status == :blocked

      refute_receive {:trigger_deliberation, _, _}, 500
    end

    test "no deliberation when no matching workflow", %{
      workspace: workspace,
      agent: agent
    } do
      rule = create_flag_rule(workspace)
      insert_rules_into_cache(workspace.id, [rule])

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberations:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :tool_call,
          content: "Flagged but no workflow"
        })

      {:ok, evaluated} = Gateway.evaluate_event(event, workspace.id)
      assert evaluated.status == :flagged

      refute_receive {:trigger_deliberation, _, _}, 500
    end

    test "disabled workflow not selected even if trigger matches", %{
      workspace: workspace,
      agent: agent
    } do
      _disabled_wf =
        workflow_fixture(%{
          workspace_id: workspace.id,
          trigger_on: :flagged,
          enabled: false
        })

      rule = create_flag_rule(workspace)
      insert_rules_into_cache(workspace.id, [rule])

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberations:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :tool_call,
          content: "Flagged event"
        })

      {:ok, _evaluated} = Gateway.evaluate_event(event, workspace.id)

      refute_receive {:trigger_deliberation, _, _}, 500
    end

    test "workflow with trigger_on :all matches flagged events", %{
      workspace: workspace,
      agent: agent
    } do
      workflow = workflow_fixture(%{workspace_id: workspace.id, trigger_on: :all})

      rule = create_flag_rule(workspace)
      insert_rules_into_cache(workspace.id, [rule])

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberations:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :tool_call,
          content: "Suspicious"
        })

      {:ok, _evaluated} = Gateway.evaluate_event(event, workspace.id)

      assert_receive {:trigger_deliberation, _event_id, received_wf}, 2000
      assert received_wf.id == workflow.id
    end

    test "creates audit entry for deliberation trigger", %{
      workspace: workspace,
      agent: agent
    } do
      _workflow = workflow_fixture(%{workspace_id: workspace.id, trigger_on: :flagged})

      rule = create_flag_rule(workspace)
      insert_rules_into_cache(workspace.id, [rule])

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :tool_call,
          content: "Audit test"
        })

      {:ok, _evaluated} = Gateway.evaluate_event(event, workspace.id)

      # Wait for async task to complete
      Process.sleep(500)

      audit =
        from(a in AuditEntry,
          where:
            a.workspace_id == ^workspace.id and
              a.action == "deliberation.auto_triggered" and
              a.resource_id == ^event.id
        )
        |> Repo.one()

      assert audit != nil
      assert audit.metadata["trigger"] == "flagged_event"
    end

    test "deliberation trigger is async - doesn't block evaluate_event", %{
      workspace: workspace,
      agent: agent
    } do
      _workflow = workflow_fixture(%{workspace_id: workspace.id, trigger_on: :flagged})

      rule = create_flag_rule(workspace)
      insert_rules_into_cache(workspace.id, [rule])

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :tool_call,
          content: "Speed test"
        })

      {elapsed_us, {:ok, evaluated}} =
        :timer.tc(fn -> Gateway.evaluate_event(event, workspace.id) end)

      assert evaluated.status == :flagged
      # evaluate_event itself should complete in under 100ms
      # (deliberation runs async, doesn't block)
      assert elapsed_us < 100_000
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_flag_rule(workspace) do
    policy_rule_fixture(%{
      workspace_id: workspace.id,
      name: "flag-tool-call-#{System.unique_integer([:positive])}",
      rule_type: :blocklist,
      action: :flag,
      priority: 10,
      enabled: true,
      config: %{
        "list_type" => "blocklist",
        "field" => "event_type",
        "values" => ["tool_call"]
      }
    })
  end

  defp create_block_rule(workspace) do
    policy_rule_fixture(%{
      workspace_id: workspace.id,
      name: "block-error-#{System.unique_integer([:positive])}",
      rule_type: :blocklist,
      action: :block,
      priority: 100,
      enabled: true,
      config: %{
        "list_type" => "blocklist",
        "field" => "event_type",
        "values" => ["error"]
      }
    })
  end

  defp insert_rules_into_cache(workspace_id, rules) do
    :ets.insert(:policy_rules_cache, {workspace_id, rules})
  end
end
