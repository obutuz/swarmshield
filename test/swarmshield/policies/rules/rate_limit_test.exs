defmodule Swarmshield.Policies.Rules.RateLimitTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Policies.Rules.RateLimit

  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.PoliciesFixtures

  setup do
    # Ensure ETS table exists
    RateLimit.init_table()

    workspace = workspace_fixture()
    agent = registered_agent_fixture(%{workspace_id: workspace.id})

    event =
      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        event_type: :action,
        content: "test"
      })

    rule =
      policy_rule_fixture(%{
        workspace_id: workspace.id,
        rule_type: :rate_limit,
        action: :flag,
        config: %{"max_events" => 3, "window_seconds" => 60, "per" => "agent"}
      })

    %{workspace: workspace, agent: agent, event: event, rule: rule}
  end

  describe "evaluate/2" do
    test "first event for agent always passes rate limit", %{event: event, rule: rule} do
      assert {:ok, :within_limit} = RateLimit.evaluate(event, rule)
    end

    test "events within limit pass", %{event: event, rule: rule} do
      assert {:ok, :within_limit} = RateLimit.evaluate(event, rule)
      assert {:ok, :within_limit} = RateLimit.evaluate(event, rule)
      assert {:ok, :within_limit} = RateLimit.evaluate(event, rule)
    end

    test "events exceeding limit return violation", %{event: event, rule: rule} do
      # Max is 3 events
      assert {:ok, :within_limit} = RateLimit.evaluate(event, rule)
      assert {:ok, :within_limit} = RateLimit.evaluate(event, rule)
      assert {:ok, :within_limit} = RateLimit.evaluate(event, rule)

      # 4th event exceeds the limit
      assert {:violation, details} = RateLimit.evaluate(event, rule)
      assert details.current_count == 4
      assert details.max_events == 3
      assert details.window_seconds == 60
    end

    test "per-agent rate limit counts each agent separately", %{workspace: workspace, rule: rule} do
      agent1 = registered_agent_fixture(%{workspace_id: workspace.id, name: "agent-1"})
      agent2 = registered_agent_fixture(%{workspace_id: workspace.id, name: "agent-2"})

      event1 =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent1.id
        })

      event2 =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent2.id
        })

      # 3 events from agent1
      assert {:ok, :within_limit} = RateLimit.evaluate(event1, rule)
      assert {:ok, :within_limit} = RateLimit.evaluate(event1, rule)
      assert {:ok, :within_limit} = RateLimit.evaluate(event1, rule)

      # Agent2 should still be within limit (separate counter)
      assert {:ok, :within_limit} = RateLimit.evaluate(event2, rule)
    end

    test "per-workspace rate limit counts all agents together", %{workspace: workspace} do
      agent1 = registered_agent_fixture(%{workspace_id: workspace.id, name: "ws-agent-1"})
      agent2 = registered_agent_fixture(%{workspace_id: workspace.id, name: "ws-agent-2"})

      event1 =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent1.id
        })

      event2 =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent2.id
        })

      workspace_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :rate_limit,
          action: :flag,
          config: %{"max_events" => 3, "window_seconds" => 60, "per" => "workspace"}
        })

      # 2 from agent1, 1 from agent2 = 3 total (at limit)
      assert {:ok, :within_limit} = RateLimit.evaluate(event1, workspace_rule)
      assert {:ok, :within_limit} = RateLimit.evaluate(event1, workspace_rule)
      assert {:ok, :within_limit} = RateLimit.evaluate(event2, workspace_rule)

      # 4th event from either agent exceeds workspace-level limit
      assert {:violation, _details} = RateLimit.evaluate(event2, workspace_rule)
    end

    test "rate limit counter key includes workspace_id (cross-workspace isolation)",
         %{rule: rule} do
      workspace1 = workspace_fixture()
      workspace2 = workspace_fixture()

      agent1 = registered_agent_fixture(%{workspace_id: workspace1.id, name: "iso-agent"})
      agent2 = registered_agent_fixture(%{workspace_id: workspace2.id, name: "iso-agent"})

      event1 =
        agent_event_fixture(%{
          workspace_id: workspace1.id,
          registered_agent_id: agent1.id
        })

      event2 =
        agent_event_fixture(%{
          workspace_id: workspace2.id,
          registered_agent_id: agent2.id
        })

      # Exhaust limit in workspace1
      RateLimit.evaluate(event1, rule)
      RateLimit.evaluate(event1, rule)
      RateLimit.evaluate(event1, rule)

      # workspace2 should be unaffected
      assert {:ok, :within_limit} = RateLimit.evaluate(event2, rule)
    end

    test "handles invalid max_events config", %{event: event, workspace: workspace} do
      bad_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :rate_limit,
          action: :flag,
          config: %{"max_events" => -1, "window_seconds" => 60}
        })

      assert {:ok, :within_limit} = RateLimit.evaluate(event, bad_rule)
    end

    test "handles invalid window_seconds config", %{event: event, workspace: workspace} do
      bad_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :rate_limit,
          action: :flag,
          config: %{"max_events" => 10, "window_seconds" => 0}
        })

      assert {:ok, :within_limit} = RateLimit.evaluate(event, bad_rule)
    end

    test "rejects config exceeding upper bounds", %{event: event, workspace: workspace} do
      huge_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :rate_limit,
          action: :flag,
          config: %{"max_events" => 2_000_000, "window_seconds" => 60}
        })

      # Should pass without evaluating (safety limit)
      assert {:ok, :within_limit} = RateLimit.evaluate(event, huge_rule)
    end
  end
end
