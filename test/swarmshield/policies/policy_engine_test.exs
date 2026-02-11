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

  describe "composite rule evaluation (POLICY-009)" do
    test "rate_limit rule violation triggers :block", %{workspace: workspace, agent: agent} do
      # Create a rate_limit rule with max_events: 1
      _rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :rate_limit,
          action: :block,
          priority: 50,
          config: %{"max_events" => 1, "window_seconds" => 60, "per" => "agent"}
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      # First event passes
      event1 =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "first event"
        })

      {action1, _matched1, _details1} = PolicyEngine.evaluate(event1, workspace.id)
      assert action1 == :allow

      # Second event exceeds the limit
      event2 =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "second event"
        })

      {action2, matched2, details2} = PolicyEngine.evaluate(event2, workspace.id)
      assert action2 == :block
      assert details2.block_count == 1
      assert Enum.any?(matched2, fn m -> m.rule_type == :rate_limit end)
    end

    test "pattern_match rule violation triggers :flag", %{workspace: workspace, agent: agent} do
      # Create a detection rule
      detection_rule =
        detection_rule_fixture(%{
          workspace_id: workspace.id,
          detection_type: :keyword,
          keywords: ["secret_data"],
          enabled: true,
          name: "secret-detect",
          pattern: nil
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      # Create a pattern_match policy rule referencing the detection rule
      _rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :pattern_match,
          action: :flag,
          priority: 30,
          config: %{"detection_rule_ids" => [detection_rule.id]}
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "This contains secret_data inside"
        })

      {action, matched, details} = PolicyEngine.evaluate(event, workspace.id)
      assert action == :flag
      assert details.flag_count == 1
      assert Enum.any?(matched, fn m -> m.rule_type == :pattern_match end)
    end

    test "blocklist rule violation triggers :block", %{workspace: workspace} do
      agent_obj = registered_agent_fixture(%{workspace_id: workspace.id, name: "bad-bot"})

      _rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :blocklist,
          action: :block,
          priority: 90,
          config: %{
            "list_type" => "blocklist",
            "field" => "agent_name",
            "values" => ["bad-bot"]
          }
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent_obj.id,
          content: "from a bad bot"
        })
        |> Swarmshield.Repo.preload(:registered_agent)

      {action, matched, _details} = PolicyEngine.evaluate(event, workspace.id)
      assert action == :block
      assert Enum.any?(matched, fn m -> m.rule_type == :blocklist end)
    end

    test "payload_size rule violation triggers :flag", %{workspace: workspace, agent: agent} do
      _rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :flag,
          priority: 20,
          config: %{"max_content_bytes" => 5}
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "this content is way over 5 bytes"
        })

      {action, matched, details} = PolicyEngine.evaluate(event, workspace.id)
      assert action == :flag
      assert details.flag_count == 1
      assert Enum.any?(matched, fn m -> m.rule_type == :payload_size end)
    end

    test "block short-circuits evaluation - remaining rules not evaluated", %{
      workspace: workspace,
      agent: agent
    } do
      # High priority block rule
      _block_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :block,
          priority: 100,
          name: "size-block",
          config: %{"max_content_bytes" => 5}
        })

      # Low priority flag rule (should not be evaluated)
      _flag_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :flag,
          priority: 10,
          name: "size-flag",
          config: %{"max_content_bytes" => 5}
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "more than five bytes here"
        })

      {action, matched, details} = PolicyEngine.evaluate(event, workspace.id)
      assert action == :block
      # Only 1 rule evaluated (short-circuited)
      assert details.evaluated_count == 1
      assert details.block_count == 1
      assert length(matched) == 1
    end

    test "multiple flag matches all collected", %{workspace: workspace, agent: agent} do
      _flag_rule1 =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :flag,
          priority: 50,
          name: "flag-size-1",
          config: %{"max_content_bytes" => 5}
        })

      _flag_rule2 =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :flag,
          priority: 40,
          name: "flag-size-2",
          config: %{"max_content_bytes" => 3}
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "more than five bytes here"
        })

      {action, matched, details} = PolicyEngine.evaluate(event, workspace.id)
      assert action == :flag
      assert details.flag_count == 2
      assert length(matched) == 2
    end

    test "mixed rule types: flag + allow = flag", %{workspace: workspace, agent: agent} do
      # Flag rule that will match
      _flag_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :flag,
          priority: 50,
          name: "flag-size",
          config: %{"max_content_bytes" => 5}
        })

      # Rate limit rule that won't trigger (generous limit)
      _allow_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :rate_limit,
          action: :block,
          priority: 90,
          name: "generous-rate",
          config: %{"max_events" => 10_000, "window_seconds" => 60, "per" => "agent"}
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "more than five bytes here"
        })

      {action, _matched, details} = PolicyEngine.evaluate(event, workspace.id)
      assert action == :flag
      assert details.evaluated_count == 2
      assert details.flag_count == 1
    end

    test "unknown rule_type is logged and skipped", %{workspace: workspace, agent: agent} do
      # Create a custom rule (treated as no_violation)
      _rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :custom,
          action: :flag,
          priority: 50,
          config: %{"custom_key" => "custom_value"}
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "normal event"
        })

      {action, matched, details} = PolicyEngine.evaluate(event, workspace.id)
      assert action == :allow
      assert matched == []
      assert details.evaluated_count == 1
    end

    test "allowlist rule violation triggers :block", %{workspace: workspace} do
      agent_obj = registered_agent_fixture(%{workspace_id: workspace.id, name: "unknown-bot"})

      _rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :allowlist,
          action: :block,
          priority: 80,
          config: %{
            "list_type" => "allowlist",
            "field" => "agent_name",
            "values" => ["approved-bot-only"]
          }
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent_obj.id,
          content: "from unknown bot"
        })
        |> Swarmshield.Repo.preload(:registered_agent)

      {action, matched, _details} = PolicyEngine.evaluate(event, workspace.id)
      assert action == :block
      assert Enum.any?(matched, fn m -> m.rule_type == :allowlist end)
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
