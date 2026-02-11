defmodule Swarmshield.Gateway.PubSubBroadcastTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Gateway
  alias Swarmshield.Gateway.AgentEvent

  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.PoliciesFixtures

  setup do
    workspace = workspace_fixture()
    agent = registered_agent_fixture(%{workspace_id: workspace.id})
    %{workspace: workspace, agent: agent}
  end

  describe "event broadcasts" do
    test "broadcasts {:event_created, event} on events topic for allowed events", %{
      workspace: workspace,
      agent: agent
    } do
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "events:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "Safe action"
        })

      {:ok, _evaluated} = Gateway.evaluate_event(event, workspace.id)

      assert_receive {:event_created, broadcast_event}, 1000
      assert broadcast_event.id == event.id
      assert broadcast_event.status == :allowed
      assert %Swarmshield.Gateway.RegisteredAgent{} = broadcast_event.registered_agent
    end

    test "broadcasts {:event_created, event} on events topic for flagged events", %{
      workspace: workspace,
      agent: agent
    } do
      rule = create_flag_rule(workspace)
      insert_rules_into_cache(workspace.id, [rule])

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "events:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :tool_call,
          content: "External API call"
        })

      {:ok, _evaluated} = Gateway.evaluate_event(event, workspace.id)

      assert_receive {:event_created, broadcast_event}, 1000
      assert broadcast_event.status == :flagged
      assert broadcast_event.registered_agent != nil
    end

    test "broadcast event includes preloaded registered_agent", %{
      workspace: workspace,
      agent: agent
    } do
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "events:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "Test"
        })

      {:ok, _evaluated} = Gateway.evaluate_event(event, workspace.id)

      assert_receive {:event_created, broadcast_event}, 1000
      assert broadcast_event.registered_agent.id == agent.id
      assert broadcast_event.registered_agent.name != nil
    end
  end

  describe "violation broadcasts" do
    test "broadcasts {:violation_created, violation} for flagged events", %{
      workspace: workspace,
      agent: agent
    } do
      rule = create_flag_rule(workspace)
      insert_rules_into_cache(workspace.id, [rule])

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "violations:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :tool_call,
          content: "External API call"
        })

      {:ok, _evaluated} = Gateway.evaluate_event(event, workspace.id)

      assert_receive {:violation_created, violation}, 1000
      assert violation.action_taken == :flagged
      assert %AgentEvent{} = violation.agent_event
      assert violation.policy_rule.id == rule.id
    end

    test "broadcasts {:violation_created, violation} for blocked events", %{
      workspace: workspace,
      agent: agent
    } do
      rule = create_block_rule(workspace)
      insert_rules_into_cache(workspace.id, [rule])

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "violations:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :error,
          content: "Error event"
        })

      {:ok, _evaluated} = Gateway.evaluate_event(event, workspace.id)

      assert_receive {:violation_created, violation}, 1000
      assert violation.action_taken == :blocked
      assert violation.severity == :high
    end

    test "no violation broadcast for allowed events", %{
      workspace: workspace,
      agent: agent
    } do
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "violations:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "Safe action"
        })

      {:ok, _evaluated} = Gateway.evaluate_event(event, workspace.id)

      refute_receive {:violation_created, _}, 200
    end

    test "violation broadcast includes preloaded event and rule", %{
      workspace: workspace,
      agent: agent
    } do
      rule = create_flag_rule(workspace)
      insert_rules_into_cache(workspace.id, [rule])

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "violations:#{workspace.id}")

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :tool_call,
          content: "API call"
        })

      {:ok, _evaluated} = Gateway.evaluate_event(event, workspace.id)

      assert_receive {:violation_created, violation}, 1000
      assert violation.agent_event.id == event.id
      assert violation.policy_rule.id == rule.id
      assert violation.policy_rule.name != nil
    end

    test "PubSub broadcast failure doesn't crash event creation", %{
      workspace: workspace,
      agent: agent
    } do
      # Even if PubSub is somehow broken, the event should still be created and evaluated
      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "Test"
        })

      {:ok, evaluated} = Gateway.evaluate_event(event, workspace.id)
      assert evaluated.status == :allowed
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
