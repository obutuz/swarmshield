defmodule Swarmshield.Policies.Rules.PatternMatchTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Policies.PolicyCache
  alias Swarmshield.Policies.Rules.PatternMatch

  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.PoliciesFixtures

  setup do
    workspace = workspace_fixture()
    agent = registered_agent_fixture(%{workspace_id: workspace.id})

    event =
      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        event_type: :action,
        content: "The user password is secret123"
      })

    # Create detection rules
    regex_rule =
      detection_rule_fixture(%{
        workspace_id: workspace.id,
        detection_type: :regex,
        pattern: "\\b(password|secret)\\b",
        enabled: true,
        name: "pii-regex"
      })

    keyword_rule =
      detection_rule_fixture(%{
        workspace_id: workspace.id,
        detection_type: :keyword,
        keywords: ["secret", "confidential"],
        enabled: true,
        name: "keyword-detect",
        pattern: nil
      })

    disabled_rule =
      detection_rule_fixture(%{
        workspace_id: workspace.id,
        detection_type: :regex,
        pattern: ".*",
        enabled: false,
        name: "disabled-rule"
      })

    # Refresh cache to load detection rules
    PolicyCache.refresh(workspace.id)
    _ = :sys.get_state(PolicyCache)
    Process.sleep(600)

    policy_rule =
      policy_rule_fixture(%{
        workspace_id: workspace.id,
        rule_type: :pattern_match,
        action: :flag,
        config: %{
          "detection_rule_ids" => [regex_rule.id, keyword_rule.id, disabled_rule.id]
        }
      })

    %{
      workspace: workspace,
      event: event,
      policy_rule: policy_rule,
      regex_rule: regex_rule,
      keyword_rule: keyword_rule,
      disabled_rule: disabled_rule
    }
  end

  describe "evaluate/2" do
    test "regex match returns violation", %{event: event, policy_rule: rule} do
      assert {:violation, details} = PatternMatch.evaluate(event, rule)
      assert is_list(details.matched_patterns)
      assert details.matched_patterns != []
      assert is_list(details.detection_rule_ids)
    end

    test "keyword match returns violation", %{event: event, policy_rule: rule} do
      assert {:violation, details} = PatternMatch.evaluate(event, rule)
      assert is_list(details.detection_rule_ids)
    end

    test "no match returns :ok", %{workspace: workspace, policy_rule: rule} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "safe-agent"})

      safe_event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "This is a perfectly safe message"
        })

      assert {:ok, :no_match} = PatternMatch.evaluate(safe_event, rule)
    end

    test "empty content returns no match", %{workspace: workspace, policy_rule: rule} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "empty-agent"})

      # Create valid event then set content to empty in-memory
      # (changeset correctly requires non-blank content, but engine must handle it)
      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "placeholder"
        })

      empty_event = %{event | content: ""}

      # Empty content won't match keyword "secret" or regex pattern
      result = PatternMatch.evaluate(empty_event, rule)
      assert result == {:ok, :no_match}
    end

    test "disabled detection rules are skipped", %{
      workspace: workspace,
      disabled_rule: disabled_rule
    } do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "disabled-test"})

      # Content that would match ".*" if the disabled rule were active
      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "anything"
        })

      # Policy rule referencing ONLY the disabled detection rule
      disabled_only_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :pattern_match,
          action: :flag,
          config: %{"detection_rule_ids" => [disabled_rule.id]}
        })

      assert {:ok, :no_match} = PatternMatch.evaluate(event, disabled_only_rule)
    end

    test "multiple detection rules - all matches reported", %{
      event: event,
      policy_rule: rule,
      regex_rule: regex_rule,
      keyword_rule: keyword_rule
    } do
      assert {:violation, details} = PatternMatch.evaluate(event, rule)

      # Both regex and keyword rules should match
      assert regex_rule.id in details.detection_rule_ids
      assert keyword_rule.id in details.detection_rule_ids
    end

    test "unicode content matches correctly", %{workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "unicode-agent"})

      unicode_rule =
        detection_rule_fixture(%{
          workspace_id: workspace.id,
          detection_type: :keyword,
          keywords: ["contraseña"],
          enabled: true,
          name: "unicode-keyword",
          pattern: nil
        })

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Mi contraseña es 12345"
        })

      policy_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :pattern_match,
          action: :flag,
          config: %{"detection_rule_ids" => [unicode_rule.id]}
        })

      assert {:violation, _details} = PatternMatch.evaluate(event, policy_rule)
    end

    test "no detection rules referenced returns no match", %{workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "no-rules-agent"})

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "test content"
        })

      # Create valid rule then modify config in-memory to test empty-ids edge case
      # (changeset correctly rejects empty detection_rule_ids, but engine must handle it)
      base_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :pattern_match,
          action: :flag,
          config: %{"detection_rule_ids" => [Ecto.UUID.generate()]}
        })

      empty_ids_rule = %{base_rule | config: %{"detection_rule_ids" => []}}

      assert {:ok, :no_match} = PatternMatch.evaluate(event, empty_ids_rule)
    end

    test "results do NOT include matched content snippets", %{event: event, policy_rule: rule} do
      assert {:violation, details} = PatternMatch.evaluate(event, rule)

      # Security: no content snippets leaked
      refute Map.has_key?(details, :matched_content)
      refute Map.has_key?(details, :content_snippet)
    end
  end
end
