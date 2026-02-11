defmodule Swarmshield.PoliciesTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Policies

  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.PoliciesFixtures

  # ---------------------------------------------------------------------------
  # PolicyRule CRUD
  # ---------------------------------------------------------------------------

  describe "list_policy_rules/2" do
    test "returns rules scoped to workspace" do
      workspace = workspace_fixture()
      other_workspace = workspace_fixture()

      rule = policy_rule_fixture(%{workspace_id: workspace.id})
      _other_rule = policy_rule_fixture(%{workspace_id: other_workspace.id})

      {rules, total_count} = Policies.list_policy_rules(workspace.id)

      assert total_count == 1
      assert [returned] = rules
      assert returned.id == rule.id
    end

    test "returns empty list for workspace with no rules" do
      workspace = workspace_fixture()

      {rules, total_count} = Policies.list_policy_rules(workspace.id)

      assert rules == []
      assert total_count == 0
    end

    test "filters by rule_type" do
      workspace = workspace_fixture()
      _rate = policy_rule_fixture(%{workspace_id: workspace.id, rule_type: :rate_limit})

      blocklist =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :blocklist,
          config: %{"values" => ["test"]}
        })

      {rules, total_count} = Policies.list_policy_rules(workspace.id, rule_type: :blocklist)

      assert total_count == 1
      assert [returned] = rules
      assert returned.id == blocklist.id
    end

    test "filters by action" do
      workspace = workspace_fixture()
      _flag = policy_rule_fixture(%{workspace_id: workspace.id, action: :flag})
      block = policy_rule_fixture(%{workspace_id: workspace.id, action: :block})

      {rules, total_count} = Policies.list_policy_rules(workspace.id, action: :block)

      assert total_count == 1
      assert [returned] = rules
      assert returned.id == block.id
    end

    test "filters by enabled" do
      workspace = workspace_fixture()
      _enabled = policy_rule_fixture(%{workspace_id: workspace.id, enabled: true})
      disabled = policy_rule_fixture(%{workspace_id: workspace.id, enabled: false})

      {rules, total_count} = Policies.list_policy_rules(workspace.id, enabled: false)

      assert total_count == 1
      assert [returned] = rules
      assert returned.id == disabled.id
    end

    test "filters by search (case-insensitive)" do
      workspace = workspace_fixture()
      target = policy_rule_fixture(%{workspace_id: workspace.id, name: "RateBlocker"})
      _other = policy_rule_fixture(%{workspace_id: workspace.id, name: "generic-rule"})

      {rules, total_count} = Policies.list_policy_rules(workspace.id, search: "rateblocker")

      assert total_count == 1
      assert [returned] = rules
      assert returned.id == target.id
    end

    test "paginates results correctly" do
      workspace = workspace_fixture()

      for _ <- 1..5 do
        policy_rule_fixture(%{workspace_id: workspace.id})
      end

      {page1, total} = Policies.list_policy_rules(workspace.id, page: 1, page_size: 2)
      assert total == 5
      assert length(page1) == 2

      {page3, _} = Policies.list_policy_rules(workspace.id, page: 3, page_size: 2)
      assert length(page3) == 1
    end
  end

  describe "list_enabled_policy_rules/1" do
    test "returns only enabled rules ordered by priority DESC" do
      workspace = workspace_fixture()

      high = policy_rule_fixture(%{workspace_id: workspace.id, priority: 100, enabled: true})
      low = policy_rule_fixture(%{workspace_id: workspace.id, priority: 1, enabled: true})
      _disabled = policy_rule_fixture(%{workspace_id: workspace.id, priority: 50, enabled: false})

      rules = Policies.list_enabled_policy_rules(workspace.id)

      assert length(rules) == 2
      assert [first, second] = rules
      assert first.id == high.id
      assert second.id == low.id
    end
  end

  describe "get_policy_rule!/1" do
    test "returns the rule with the given id" do
      rule = policy_rule_fixture()

      returned = Policies.get_policy_rule!(rule.id)

      assert returned.id == rule.id
      assert returned.name == rule.name
    end

    test "raises on non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Policies.get_policy_rule!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_policy_rule/3" do
    test "creates a policy rule and broadcasts PubSub event" do
      workspace = workspace_fixture()
      Policies.subscribe_policy_rules(workspace.id)

      attrs = %{
        name: "test-rate-limit",
        description: "Rate limit test",
        rule_type: :rate_limit,
        action: :flag,
        priority: 50,
        config: %{"max_events" => 100, "window_seconds" => 60}
      }

      assert {:ok, rule} = Policies.create_policy_rule(workspace.id, attrs)

      assert rule.name == "test-rate-limit"
      assert rule.rule_type == :rate_limit
      assert rule.action == :flag
      assert rule.workspace_id == workspace.id
      assert rule.enabled == true

      # PubSub broadcast received
      assert_receive {:policy_rules_changed, :created, rule_id}
      assert rule_id == rule.id
    end

    test "returns error for invalid attrs" do
      workspace = workspace_fixture()

      assert {:error, changeset} =
               Policies.create_policy_rule(workspace.id, %{name: ""})

      assert errors_on(changeset).name != nil
    end

    test "creates audit entry on create" do
      workspace = workspace_fixture()

      {:ok, _rule} =
        Policies.create_policy_rule(workspace.id, %{
          name: "audit-test",
          rule_type: :rate_limit,
          action: :flag,
          config: %{"max_events" => 10, "window_seconds" => 60}
        })

      {entries, _} =
        Swarmshield.Accounts.list_audit_entries(workspace.id, action: "policy_rule.created")

      assert length(entries) == 1
      assert hd(entries).action == "policy_rule.created"
    end
  end

  describe "update_policy_rule/3" do
    test "updates and broadcasts PubSub event" do
      rule = policy_rule_fixture()
      Policies.subscribe_policy_rules(rule.workspace_id)

      assert {:ok, updated} = Policies.update_policy_rule(rule, %{name: "updated-rule"})

      assert updated.name == "updated-rule"

      assert_receive {:policy_rules_changed, :updated, rule_id}
      assert rule_id == updated.id
    end

    test "creates audit entry on update" do
      rule = policy_rule_fixture()

      {:ok, _} = Policies.update_policy_rule(rule, %{name: "audit-updated"})

      {entries, _} =
        Swarmshield.Accounts.list_audit_entries(
          rule.workspace_id,
          action: "policy_rule.updated"
        )

      assert length(entries) == 1
    end
  end

  describe "delete_policy_rule/2" do
    test "deletes rule and broadcasts PubSub event" do
      rule = policy_rule_fixture()
      Policies.subscribe_policy_rules(rule.workspace_id)

      assert {:ok, deleted} = Policies.delete_policy_rule(rule)
      assert deleted.id == rule.id

      assert_receive {:policy_rules_changed, :deleted, rule_id}
      assert rule_id == deleted.id

      assert_raise Ecto.NoResultsError, fn ->
        Policies.get_policy_rule!(rule.id)
      end
    end

    test "returns error when rule has linked violations" do
      workspace = workspace_fixture()
      rule = policy_rule_fixture(%{workspace_id: workspace.id})

      _violation =
        policy_violation_fixture(%{
          workspace_id: workspace.id,
          policy_rule_id: rule.id
        })

      assert {:error, _changeset} = Policies.delete_policy_rule(rule)

      # Rule still exists
      assert Policies.get_policy_rule!(rule.id).id == rule.id
    end

    test "creates audit entry on delete" do
      rule = policy_rule_fixture()
      workspace_id = rule.workspace_id

      {:ok, _} = Policies.delete_policy_rule(rule)

      {entries, _} =
        Swarmshield.Accounts.list_audit_entries(workspace_id, action: "policy_rule.deleted")

      assert length(entries) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # DetectionRule CRUD
  # ---------------------------------------------------------------------------

  describe "list_detection_rules/2" do
    test "returns rules scoped to workspace" do
      workspace = workspace_fixture()
      other_workspace = workspace_fixture()

      rule = detection_rule_fixture(%{workspace_id: workspace.id})
      _other_rule = detection_rule_fixture(%{workspace_id: other_workspace.id})

      {rules, total_count} = Policies.list_detection_rules(workspace.id)

      assert total_count == 1
      assert [returned] = rules
      assert returned.id == rule.id
    end

    test "filters by detection_type" do
      workspace = workspace_fixture()
      _regex = detection_rule_fixture(%{workspace_id: workspace.id, detection_type: :regex})

      keyword =
        detection_rule_fixture(%{
          workspace_id: workspace.id,
          detection_type: :keyword,
          keywords: ["test"],
          pattern: nil
        })

      {rules, total_count} =
        Policies.list_detection_rules(workspace.id, detection_type: :keyword)

      assert total_count == 1
      assert [returned] = rules
      assert returned.id == keyword.id
    end

    test "filters by category" do
      workspace = workspace_fixture()
      _pii = detection_rule_fixture(%{workspace_id: workspace.id, category: "pii"})

      toxicity =
        detection_rule_fixture(%{workspace_id: workspace.id, category: "toxicity"})

      {rules, total_count} =
        Policies.list_detection_rules(workspace.id, category: "toxicity")

      assert total_count == 1
      assert [returned] = rules
      assert returned.id == toxicity.id
    end

    test "filters by enabled" do
      workspace = workspace_fixture()
      _enabled = detection_rule_fixture(%{workspace_id: workspace.id, enabled: true})
      disabled = detection_rule_fixture(%{workspace_id: workspace.id, enabled: false})

      {rules, total_count} =
        Policies.list_detection_rules(workspace.id, enabled: false)

      assert total_count == 1
      assert [returned] = rules
      assert returned.id == disabled.id
    end
  end

  describe "list_enabled_detection_rules/1" do
    test "returns only enabled detection rules" do
      workspace = workspace_fixture()
      enabled = detection_rule_fixture(%{workspace_id: workspace.id, enabled: true})
      _disabled = detection_rule_fixture(%{workspace_id: workspace.id, enabled: false})

      rules = Policies.list_enabled_detection_rules(workspace.id)

      assert length(rules) == 1
      assert hd(rules).id == enabled.id
    end
  end

  describe "get_detection_rule!/1" do
    test "returns the rule" do
      rule = detection_rule_fixture()

      returned = Policies.get_detection_rule!(rule.id)

      assert returned.id == rule.id
    end

    test "raises on non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Policies.get_detection_rule!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_detection_rule/3" do
    test "creates rule and broadcasts PubSub event" do
      workspace = workspace_fixture()
      Policies.subscribe_detection_rules(workspace.id)

      attrs = %{
        name: "prompt-injection-detect",
        detection_type: :regex,
        pattern: "ignore.*instructions",
        severity: :high,
        category: "prompt_injection"
      }

      assert {:ok, rule} = Policies.create_detection_rule(workspace.id, attrs)

      assert rule.name == "prompt-injection-detect"
      assert rule.detection_type == :regex
      assert rule.workspace_id == workspace.id

      assert_receive {:detection_rules_changed, :created, rule_id}
      assert rule_id == rule.id
    end

    test "creates audit entry" do
      workspace = workspace_fixture()

      {:ok, _rule} =
        Policies.create_detection_rule(workspace.id, %{
          name: "audit-detection",
          detection_type: :keyword,
          keywords: ["secret"]
        })

      {entries, _} =
        Swarmshield.Accounts.list_audit_entries(
          workspace.id,
          action: "detection_rule.created"
        )

      assert length(entries) == 1
    end
  end

  describe "update_detection_rule/3" do
    test "updates and broadcasts" do
      rule = detection_rule_fixture()
      Policies.subscribe_detection_rules(rule.workspace_id)

      assert {:ok, updated} =
               Policies.update_detection_rule(rule, %{name: "updated-detection"})

      assert updated.name == "updated-detection"

      assert_receive {:detection_rules_changed, :updated, rule_id}
      assert rule_id == updated.id
    end
  end

  describe "delete_detection_rule/2" do
    test "deletes and broadcasts" do
      rule = detection_rule_fixture()
      Policies.subscribe_detection_rules(rule.workspace_id)

      assert {:ok, deleted} = Policies.delete_detection_rule(rule)

      assert_receive {:detection_rules_changed, :deleted, rule_id}
      assert rule_id == deleted.id

      assert_raise Ecto.NoResultsError, fn ->
        Policies.get_detection_rule!(rule.id)
      end
    end

    test "creates audit entry on delete" do
      rule = detection_rule_fixture()
      workspace_id = rule.workspace_id

      {:ok, _} = Policies.delete_detection_rule(rule)

      {entries, _} =
        Swarmshield.Accounts.list_audit_entries(
          workspace_id,
          action: "detection_rule.deleted"
        )

      assert length(entries) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # PolicyViolation CRUD
  # ---------------------------------------------------------------------------

  describe "list_policy_violations/2" do
    test "returns violations scoped to workspace with preloads" do
      workspace = workspace_fixture()
      other_workspace = workspace_fixture()

      violation = policy_violation_fixture(%{workspace_id: workspace.id})
      _other = policy_violation_fixture(%{workspace_id: other_workspace.id})

      {violations, total_count} = Policies.list_policy_violations(workspace.id)

      assert total_count == 1
      assert [returned] = violations
      assert returned.id == violation.id
      # Preloaded associations
      assert returned.agent_event != nil
      assert returned.policy_rule != nil
    end

    test "returns empty list for workspace with no violations" do
      workspace = workspace_fixture()

      {violations, total_count} = Policies.list_policy_violations(workspace.id)

      assert violations == []
      assert total_count == 0
    end

    test "filters by action_taken" do
      workspace = workspace_fixture()
      _flagged = policy_violation_fixture(%{workspace_id: workspace.id, action_taken: :flagged})
      blocked = policy_violation_fixture(%{workspace_id: workspace.id, action_taken: :blocked})

      {violations, total_count} =
        Policies.list_policy_violations(workspace.id, action_taken: :blocked)

      assert total_count == 1
      assert [returned] = violations
      assert returned.id == blocked.id
    end

    test "filters by severity" do
      workspace = workspace_fixture()
      _medium = policy_violation_fixture(%{workspace_id: workspace.id, severity: :medium})
      critical = policy_violation_fixture(%{workspace_id: workspace.id, severity: :critical})

      {violations, total_count} =
        Policies.list_policy_violations(workspace.id, severity: :critical)

      assert total_count == 1
      assert [returned] = violations
      assert returned.id == critical.id
    end

    test "filters by resolved" do
      workspace = workspace_fixture()
      user = user_fixture()

      unresolved = policy_violation_fixture(%{workspace_id: workspace.id})
      resolved_v = policy_violation_fixture(%{workspace_id: workspace.id})
      {:ok, _} = Policies.resolve_policy_violation(resolved_v, user.id, "test")

      {violations, total_count} =
        Policies.list_policy_violations(workspace.id, resolved: false)

      assert total_count == 1
      assert [returned] = violations
      assert returned.id == unresolved.id
    end

    test "paginates results" do
      workspace = workspace_fixture()

      for _ <- 1..5 do
        policy_violation_fixture(%{workspace_id: workspace.id})
      end

      {page1, total} =
        Policies.list_policy_violations(workspace.id, page: 1, page_size: 2)

      assert total == 5
      assert length(page1) == 2
    end
  end

  describe "get_policy_violation!/1" do
    test "returns violation with preloads" do
      violation = policy_violation_fixture()

      returned = Policies.get_policy_violation!(violation.id)

      assert returned.id == violation.id
      assert returned.agent_event != nil
      assert returned.policy_rule != nil
    end

    test "raises on non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Policies.get_policy_violation!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_policy_violation/1" do
    test "creates a violation with server-side IDs" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})
      event = agent_event_fixture(%{workspace_id: workspace.id, registered_agent_id: agent.id})
      rule = policy_rule_fixture(%{workspace_id: workspace.id})

      attrs = %{
        workspace_id: workspace.id,
        agent_event_id: event.id,
        policy_rule_id: rule.id,
        action_taken: :flagged,
        severity: :high,
        details: %{"matched" => true}
      }

      assert {:ok, violation} = Policies.create_policy_violation(attrs)

      assert violation.workspace_id == workspace.id
      assert violation.agent_event_id == event.id
      assert violation.policy_rule_id == rule.id
      assert violation.action_taken == :flagged
      assert violation.severity == :high
      assert violation.resolved == false
    end
  end

  describe "resolve_policy_violation/3" do
    test "resolves an unresolved violation" do
      violation = policy_violation_fixture()
      user = user_fixture()

      assert {:ok, resolved} =
               Policies.resolve_policy_violation(violation, user.id, "False positive")

      assert resolved.resolved == true
      assert resolved.resolved_by_id == user.id
      assert resolved.resolved_at != nil
      assert resolved.resolution_notes == "False positive"
    end

    test "resolves without notes" do
      violation = policy_violation_fixture()
      user = user_fixture()

      assert {:ok, resolved} = Policies.resolve_policy_violation(violation, user.id)

      assert resolved.resolved == true
      assert resolved.resolution_notes == nil
    end

    test "returns error for already resolved violation" do
      violation = policy_violation_fixture()
      user = user_fixture()

      {:ok, resolved} = Policies.resolve_policy_violation(violation, user.id, "first")

      assert {:error, :already_resolved} =
               Policies.resolve_policy_violation(resolved, user.id, "second")
    end

    test "creates audit entry on resolve" do
      violation = policy_violation_fixture()
      user = user_fixture()

      {:ok, _} = Policies.resolve_policy_violation(violation, user.id, "test notes")

      {entries, _} =
        Swarmshield.Accounts.list_audit_entries(
          violation.workspace_id,
          action: "policy_violation.resolved"
        )

      assert length(entries) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  describe "PubSub broadcasts" do
    test "policy rule broadcasts include workspace_id in topic" do
      workspace = workspace_fixture()

      # Subscribe to specific workspace topic
      Policies.subscribe_policy_rules(workspace.id)

      {:ok, rule} =
        Policies.create_policy_rule(workspace.id, %{
          name: "pubsub-test",
          rule_type: :rate_limit,
          action: :flag,
          config: %{"max_events" => 10, "window_seconds" => 60}
        })

      # Should receive because we're subscribed to this workspace
      rule_id = rule.id
      assert_receive {:policy_rules_changed, :created, ^rule_id}
    end

    test "detection rule broadcasts include workspace_id in topic" do
      workspace = workspace_fixture()
      Policies.subscribe_detection_rules(workspace.id)

      {:ok, rule} =
        Policies.create_detection_rule(workspace.id, %{
          name: "pubsub-detection",
          detection_type: :keyword,
          keywords: ["test"]
        })

      rule_id = rule.id
      assert_receive {:detection_rules_changed, :created, ^rule_id}
    end

    test "broadcasts do NOT include sensitive rule config data" do
      workspace = workspace_fixture()
      Policies.subscribe_policy_rules(workspace.id)

      {:ok, _rule} =
        Policies.create_policy_rule(workspace.id, %{
          name: "security-test",
          rule_type: :rate_limit,
          action: :flag,
          config: %{"max_events" => 10, "window_seconds" => 60}
        })

      # Message only contains action and ID - no config data
      assert_receive {:policy_rules_changed, action, rule_id}
      assert action == :created
      assert is_binary(rule_id)
      # The message is a 3-element tuple: {atom, atom, binary} - no config
    end
  end
end
