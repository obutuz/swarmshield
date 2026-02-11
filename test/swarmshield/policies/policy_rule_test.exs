defmodule Swarmshield.Policies.PolicyRuleTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Policies.PolicyRule
  alias Swarmshield.PoliciesFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = PoliciesFixtures.valid_policy_rule_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      changeset = PolicyRule.changeset(%PolicyRule{workspace_id: workspace.id}, attrs)

      assert changeset.valid?
    end

    test "requires name" do
      attrs = PoliciesFixtures.valid_policy_rule_attributes(%{name: nil})
      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires rule_type" do
      attrs = PoliciesFixtures.valid_policy_rule_attributes(%{rule_type: nil})
      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{rule_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires action" do
      attrs = PoliciesFixtures.valid_policy_rule_attributes(%{action: nil})
      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{action: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires config" do
      attrs = PoliciesFixtures.valid_policy_rule_attributes(%{config: nil})
      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{config: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name max length" do
      long_name = String.duplicate("a", 256)
      attrs = PoliciesFixtures.valid_policy_rule_attributes(%{name: long_name})
      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "validates description max length" do
      long_desc = String.duplicate("a", 2001)
      attrs = PoliciesFixtures.valid_policy_rule_attributes(%{description: long_desc})
      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{description: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 2000"
    end

    test "accepts all valid rule_types" do
      for rule_type <- [
            :rate_limit,
            :pattern_match,
            :blocklist,
            :allowlist,
            :payload_size,
            :custom
          ] do
        config =
          case rule_type do
            :rate_limit -> %{"max_events" => 100, "window_seconds" => 60}
            :pattern_match -> %{"detection_rule_ids" => ["abc"]}
            :blocklist -> %{"values" => ["bad"]}
            :allowlist -> %{"values" => ["good"]}
            :payload_size -> %{"max_content_bytes" => 1024}
            :custom -> %{"any" => "config"}
          end

        attrs =
          PoliciesFixtures.valid_policy_rule_attributes(%{rule_type: rule_type, config: config})

        changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

        assert changeset.valid?,
               "Expected rule_type #{rule_type} to be valid, got: #{inspect(errors_on(changeset))}"
      end
    end

    test "rejects invalid rule_type" do
      attrs = PoliciesFixtures.valid_policy_rule_attributes(%{rule_type: :invalid})
      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{rule_type: [_msg]} = errors_on(changeset)
    end

    test "accepts all valid actions" do
      for action <- [:allow, :flag, :block] do
        attrs = PoliciesFixtures.valid_policy_rule_attributes(%{action: action})
        changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

        assert changeset.valid?, "Expected action #{action} to be valid"
      end
    end

    test "priority defaults to 0" do
      changeset = PolicyRule.changeset(%PolicyRule{}, %{})
      assert Ecto.Changeset.get_field(changeset, :priority) == 0
    end

    test "enabled defaults to true" do
      changeset = PolicyRule.changeset(%PolicyRule{}, %{})
      assert Ecto.Changeset.get_field(changeset, :enabled) == true
    end

    test "applies_to_agent_types defaults to empty array" do
      changeset = PolicyRule.changeset(%PolicyRule{}, %{})
      assert Ecto.Changeset.get_field(changeset, :applies_to_agent_types) == []
    end

    test "applies_to_event_types defaults to empty array" do
      changeset = PolicyRule.changeset(%PolicyRule{}, %{})
      assert Ecto.Changeset.get_field(changeset, :applies_to_event_types) == []
    end
  end

  describe "config validation per rule_type" do
    test "rate_limit requires max_events" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :rate_limit,
          config: %{"window_seconds" => 60}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{config: [msg]} = errors_on(changeset)
      assert msg =~ "max_events"
    end

    test "rate_limit requires window_seconds" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :rate_limit,
          config: %{"max_events" => 100}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{config: [msg]} = errors_on(changeset)
      assert msg =~ "window_seconds"
    end

    test "rate_limit valid config passes" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :rate_limit,
          config: %{"max_events" => 100, "window_seconds" => 60}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      assert changeset.valid?
    end

    test "pattern_match requires detection_rule_ids" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :pattern_match,
          config: %{}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{config: [msg]} = errors_on(changeset)
      assert msg =~ "detection_rule_ids"
    end

    test "pattern_match requires non-empty detection_rule_ids" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :pattern_match,
          config: %{"detection_rule_ids" => []}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{config: [msg]} = errors_on(changeset)
      assert msg =~ "detection_rule_ids"
    end

    test "blocklist requires values" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :blocklist,
          config: %{}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{config: [msg]} = errors_on(changeset)
      assert msg =~ "values"
    end

    test "blocklist requires non-empty values" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :blocklist,
          config: %{"values" => []}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{config: [msg]} = errors_on(changeset)
      assert msg =~ "values"
    end

    test "payload_size requires max_content_bytes or max_payload_bytes" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :payload_size,
          config: %{}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      refute changeset.valid?
      assert %{config: [msg]} = errors_on(changeset)
      assert msg =~ "max_content_bytes"
    end

    test "payload_size valid with max_content_bytes" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :payload_size,
          config: %{"max_content_bytes" => 1024}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      assert changeset.valid?
    end

    test "payload_size valid with max_payload_bytes" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :payload_size,
          config: %{"max_payload_bytes" => 2048}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      assert changeset.valid?
    end

    test "custom type accepts any config" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :custom,
          config: %{"arbitrary" => "config", "nested" => %{"data" => true}}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      assert changeset.valid?
    end

    test "allowlist type accepts any config" do
      attrs =
        PoliciesFixtures.valid_policy_rule_attributes(%{
          rule_type: :allowlist,
          config: %{"values" => ["good"]}
        })

      changeset = PolicyRule.changeset(%PolicyRule{}, attrs)

      assert changeset.valid?
    end
  end

  describe "fixture and database persistence" do
    test "creates a policy rule with default attributes" do
      rule = PoliciesFixtures.policy_rule_fixture()

      assert rule.id
      assert rule.workspace_id
      assert rule.name
      assert rule.rule_type == :rate_limit
      assert rule.action == :flag
      assert rule.priority == 10
      assert rule.enabled == true
      assert rule.config == %{"max_events" => 100, "window_seconds" => 60}
    end

    test "creates a policy rule with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      rule =
        PoliciesFixtures.policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :blocklist,
          action: :block,
          config: %{"values" => ["malicious"]}
        })

      assert rule.rule_type == :blocklist
      assert rule.action == :block
    end

    test "reloaded rule matches inserted data" do
      rule = PoliciesFixtures.policy_rule_fixture()
      reloaded = Repo.get!(PolicyRule, rule.id)

      assert reloaded.name == rule.name
      assert reloaded.rule_type == rule.rule_type
      assert reloaded.config == rule.config
    end
  end
end
