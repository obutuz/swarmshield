defmodule Swarmshield.Policies.Rules.PayloadSizeTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Policies.Rules.PayloadSize

  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.PoliciesFixtures

  setup do
    workspace = workspace_fixture()
    agent = registered_agent_fixture(%{workspace_id: workspace.id})

    %{workspace: workspace, agent: agent}
  end

  describe "evaluate/2" do
    test "within limit passes", %{workspace: workspace, agent: agent} do
      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "short",
          payload: %{"key" => "value"}
        })

      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :block,
          config: %{"max_content_bytes" => 1000, "max_payload_bytes" => 1000}
        })

      assert {:ok, :within_limit} = PayloadSize.evaluate(event, rule)
    end

    test "content exceeding limit returns violation", %{workspace: workspace, agent: agent} do
      big_content = String.duplicate("a", 100)

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: big_content
        })

      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :block,
          config: %{"max_content_bytes" => 50, "max_payload_bytes" => 10_000}
        })

      assert {:violation, details} = PayloadSize.evaluate(event, rule)
      assert details.content_bytes == 100
      assert details.limits.max_content_bytes == 50
    end

    test "payload exceeding limit returns violation", %{workspace: workspace, agent: agent} do
      big_payload = %{"data" => String.duplicate("x", 200)}

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "ok",
          payload: big_payload
        })

      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :block,
          config: %{"max_content_bytes" => 10_000, "max_payload_bytes" => 50}
        })

      assert {:violation, details} = PayloadSize.evaluate(event, rule)
      assert details.payload_bytes > 50
      assert details.limits.max_payload_bytes == 50
    end

    test "nil content treated as 0 bytes", %{workspace: workspace, agent: agent} do
      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "x"
        })

      # Simulate nil content (normally content is required, but engine handles it)
      event_map = %{event | content: nil}

      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :block,
          config: %{"max_content_bytes" => 10}
        })

      assert {:ok, :within_limit} = PayloadSize.evaluate(event_map, rule)
    end

    test "nil payload treated as 0 bytes", %{workspace: workspace, agent: agent} do
      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "ok"
        })

      event_map = %{event | payload: nil}

      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :block,
          config: %{"max_payload_bytes" => 10}
        })

      assert {:ok, :within_limit} = PayloadSize.evaluate(event_map, rule)
    end

    test "empty string content is 0 bytes", %{workspace: workspace, agent: agent} do
      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "x"
        })

      event_map = %{event | content: ""}

      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :block,
          config: %{"max_content_bytes" => 1}
        })

      assert {:ok, :within_limit} = PayloadSize.evaluate(event_map, rule)
    end

    test "unicode content byte_size differs from String.length", %{
      workspace: workspace,
      agent: agent
    } do
      # "héllo" has 5 graphemes but 6 bytes (é is 2 bytes in UTF-8)
      unicode_content = "héllo"
      assert String.length(unicode_content) == 5
      assert byte_size(unicode_content) == 6

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: unicode_content
        })

      # Set limit between grapheme count and byte size
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :block,
          config: %{"max_content_bytes" => 5}
        })

      # Should violate because byte_size(6) > 5
      assert {:violation, details} = PayloadSize.evaluate(event, rule)
      assert details.content_bytes == 6
    end

    test "only max_content_bytes set (max_payload_bytes not checked)", %{
      workspace: workspace,
      agent: agent
    } do
      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "ok",
          payload: %{"huge" => String.duplicate("x", 10_000)}
        })

      # Only content limit, no payload limit
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :payload_size,
          action: :block,
          config: %{"max_content_bytes" => 100}
        })

      # Should pass even though payload is huge (payload limit not set)
      assert {:ok, :within_limit} = PayloadSize.evaluate(event, rule)
    end
  end
end
