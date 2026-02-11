defmodule Swarmshield.Policies.PolicyEngineTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Policies.{PolicyCache, PolicyEngine}

  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.PoliciesFixtures

  # async: false because PolicyCache uses shared ETS tables

  setup do
    workspace = workspace_fixture()
    agent = registered_agent_fixture(%{workspace_id: workspace.id})

    event =
      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        event_type: :action,
        content: "test event content"
      })

    # Preload the registered_agent association for agent_type filtering
    event = Swarmshield.Repo.preload(event, :registered_agent)

    %{workspace: workspace, agent: agent, event: event}
  end

  describe "evaluate/2 with no cached rules" do
    test "returns :allow with empty matched rules", %{event: event, workspace: workspace} do
      # Ensure cache is empty for this workspace
      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      {action, matched_rules, details} = PolicyEngine.evaluate(event, workspace.id)

      assert action == :allow
      assert matched_rules == []
      assert details.evaluated_count == 0
      assert details.block_count == 0
      assert details.flag_count == 0
      assert is_integer(details.duration_us)
      assert details.duration_us >= 0
    end
  end

  describe "evaluate/2 with cached rules" do
    test "returns :allow when no rules match", %{event: event, workspace: workspace} do
      # Create a rule but disable it so it won't be in cache
      _disabled_rule =
        policy_rule_fixture(%{workspace_id: workspace.id, enabled: false})

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      {action, matched_rules, _details} = PolicyEngine.evaluate(event, workspace.id)

      assert action == :allow
      assert matched_rules == []
    end

    test "returns duration_us in details map", %{event: event, workspace: workspace} do
      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      {_action, _matched, details} = PolicyEngine.evaluate(event, workspace.id)

      assert Map.has_key?(details, :duration_us)
      assert is_integer(details.duration_us)
    end

    test "evaluates rules in priority order", %{event: _event, workspace: workspace} do
      _high =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          name: "high-priority",
          priority: 100,
          enabled: true
        })

      _low =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          name: "low-priority",
          priority: 1,
          enabled: true
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      # Rules are loaded from cache in priority DESC order
      rules = PolicyCache.get_rules(workspace.id)
      assert length(rules) == 2
      assert hd(rules).priority >= List.last(rules).priority
    end
  end

  describe "evaluate/2 with event missing optional fields" do
    test "handles event with nil source_ip without crash", %{workspace: workspace, agent: agent} do
      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          event_type: :action,
          content: "test"
        })

      # source_ip is nil by default
      assert event.source_ip == nil

      _rule = policy_rule_fixture(%{workspace_id: workspace.id, enabled: true})

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      # Should not crash
      {action, _matched, _details} = PolicyEngine.evaluate(event, workspace.id)
      assert action in [:allow, :flag, :block]
    end
  end

  describe "applies_to_event_types filtering" do
    test "rule with empty applies_to_event_types matches all events",
         %{event: event, workspace: workspace} do
      _rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          applies_to_event_types: [],
          enabled: true
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      {_action, _matched, details} = PolicyEngine.evaluate(event, workspace.id)
      # Rule was evaluated (not filtered out)
      assert details.evaluated_count == 1
    end

    test "rule with specific event types only matches those types",
         %{workspace: workspace, agent: agent} do
      # Rule only applies to :error events
      _rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          applies_to_event_types: ["error"],
          enabled: true
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      # Create an :action event (not :error)
      action_event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          event_type: :action,
          content: "action event"
        })

      {_action, _matched, details} = PolicyEngine.evaluate(action_event, workspace.id)
      # Rule filtered out - not applicable to :action events
      assert details.evaluated_count == 0

      # Create an :error event
      error_event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          event_type: :error,
          content: "error event"
        })

      {_action, _matched, details2} = PolicyEngine.evaluate(error_event, workspace.id)
      # Rule applied to :error event
      assert details2.evaluated_count == 1
    end
  end

  describe "applies_to_agent_types filtering" do
    test "rule with empty applies_to_agent_types matches all agent types",
         %{event: event, workspace: workspace} do
      _rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          applies_to_agent_types: [],
          enabled: true
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      {_action, _matched, details} = PolicyEngine.evaluate(event, workspace.id)
      assert details.evaluated_count == 1
    end

    test "rule with specific agent types only matches those types",
         %{workspace: workspace} do
      # Create a chatbot agent
      chatbot =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          agent_type: :chatbot,
          name: "chatbot-agent"
        })

      chatbot_event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: chatbot.id,
          event_type: :action,
          content: "chatbot action"
        })
        |> Swarmshield.Repo.preload(:registered_agent)

      # Rule only applies to autonomous agents
      _rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          applies_to_agent_types: ["autonomous"],
          enabled: true
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      # Chatbot event should not match the autonomous-only rule
      {_action, _matched, details} = PolicyEngine.evaluate(chatbot_event, workspace.id)
      assert details.evaluated_count == 0
    end
  end

  describe "telemetry" do
    test "emits telemetry event on evaluation", %{event: event, workspace: workspace} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:swarmshield, :policy_engine, :evaluate]
        ])

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      PolicyEngine.evaluate(event, workspace.id)

      assert_receive {[:swarmshield, :policy_engine, :evaluate], ^ref, measurements, metadata}
      assert is_integer(measurements.duration_us)
      assert metadata.workspace_id == workspace.id
      assert metadata.action == :allow
    end
  end
end
