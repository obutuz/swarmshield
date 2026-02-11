defmodule Swarmshield.Policies.PolicyViolationTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.GatewayFixtures
  alias Swarmshield.Policies.PolicyViolation
  alias Swarmshield.PoliciesFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = PoliciesFixtures.valid_policy_violation_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      event = GatewayFixtures.agent_event_fixture(%{workspace_id: workspace.id})
      rule = PoliciesFixtures.policy_rule_fixture(%{workspace_id: workspace.id})

      changeset =
        PolicyViolation.changeset(
          %PolicyViolation{
            workspace_id: workspace.id,
            agent_event_id: event.id,
            policy_rule_id: rule.id
          },
          attrs
        )

      assert changeset.valid?
    end

    test "requires action_taken" do
      attrs = PoliciesFixtures.valid_policy_violation_attributes(%{action_taken: nil})
      changeset = PolicyViolation.changeset(%PolicyViolation{}, attrs)

      refute changeset.valid?
      assert %{action_taken: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires severity" do
      attrs = PoliciesFixtures.valid_policy_violation_attributes(%{severity: nil})
      changeset = PolicyViolation.changeset(%PolicyViolation{}, attrs)

      refute changeset.valid?
      assert %{severity: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts all valid actions_taken" do
      for action <- [:flagged, :blocked] do
        attrs = PoliciesFixtures.valid_policy_violation_attributes(%{action_taken: action})
        changeset = PolicyViolation.changeset(%PolicyViolation{}, attrs)

        assert changeset.valid?, "Expected action_taken #{action} to be valid"
      end
    end

    test "rejects invalid action_taken" do
      attrs = PoliciesFixtures.valid_policy_violation_attributes(%{action_taken: :invalid})
      changeset = PolicyViolation.changeset(%PolicyViolation{}, attrs)

      refute changeset.valid?
      assert %{action_taken: [_msg]} = errors_on(changeset)
    end

    test "accepts all valid severities" do
      for severity <- [:low, :medium, :high, :critical] do
        attrs = PoliciesFixtures.valid_policy_violation_attributes(%{severity: severity})
        changeset = PolicyViolation.changeset(%PolicyViolation{}, attrs)

        assert changeset.valid?, "Expected severity #{severity} to be valid"
      end
    end

    test "details defaults to empty map" do
      changeset = PolicyViolation.changeset(%PolicyViolation{}, %{})
      assert Ecto.Changeset.get_field(changeset, :details) == %{}
    end

    test "resolved defaults to false" do
      changeset = PolicyViolation.changeset(%PolicyViolation{}, %{})
      assert Ecto.Changeset.get_field(changeset, :resolved) == false
    end

    test "details map stores evaluation context faithfully" do
      complex_details = %{
        "matched_pattern" => "password",
        "context" => "user said password in chat",
        "rule_name" => "PII Detection",
        "scores" => %{"confidence" => 0.95, "severity_boost" => 1.2}
      }

      attrs = PoliciesFixtures.valid_policy_violation_attributes(%{details: complex_details})
      workspace = AccountsFixtures.workspace_fixture()
      event = GatewayFixtures.agent_event_fixture(%{workspace_id: workspace.id})
      rule = PoliciesFixtures.policy_rule_fixture(%{workspace_id: workspace.id})

      {:ok, violation} =
        %PolicyViolation{
          workspace_id: workspace.id,
          agent_event_id: event.id,
          policy_rule_id: rule.id
        }
        |> PolicyViolation.changeset(attrs)
        |> Repo.insert()

      assert violation.details == complex_details
    end
  end

  describe "resolution_changeset/2" do
    test "sets resolved fields" do
      user = AccountsFixtures.user_fixture()
      now = DateTime.utc_now(:second)

      changeset =
        PolicyViolation.resolution_changeset(%PolicyViolation{}, %{
          resolved: true,
          resolved_by_id: user.id,
          resolved_at: now,
          resolution_notes: "False positive"
        })

      assert changeset.valid?
    end

    test "requires resolved field" do
      changeset =
        PolicyViolation.resolution_changeset(%PolicyViolation{resolved: nil}, %{
          resolved_by_id: Ecto.UUID.generate(),
          resolved_at: DateTime.utc_now(:second)
        })

      refute changeset.valid?
      assert %{resolved: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires resolved_by_id" do
      changeset =
        PolicyViolation.resolution_changeset(%PolicyViolation{}, %{
          resolved: true,
          resolved_at: DateTime.utc_now(:second)
        })

      refute changeset.valid?
      assert %{resolved_by_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires resolved_at" do
      changeset =
        PolicyViolation.resolution_changeset(%PolicyViolation{}, %{
          resolved: true,
          resolved_by_id: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert %{resolved_at: ["can't be blank"]} = errors_on(changeset)
    end

    test "resolution_notes can be up to 5000 chars" do
      long_notes = String.duplicate("a", 5000)

      changeset =
        PolicyViolation.resolution_changeset(%PolicyViolation{}, %{
          resolved: true,
          resolved_by_id: Ecto.UUID.generate(),
          resolved_at: DateTime.utc_now(:second),
          resolution_notes: long_notes
        })

      assert changeset.valid?
    end

    test "resolution_notes exceeding 5000 chars is rejected" do
      too_long_notes = String.duplicate("a", 5001)

      changeset =
        PolicyViolation.resolution_changeset(%PolicyViolation{}, %{
          resolved: true,
          resolved_by_id: Ecto.UUID.generate(),
          resolved_at: DateTime.utc_now(:second),
          resolution_notes: too_long_notes
        })

      refute changeset.valid?
      assert %{resolution_notes: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 5000"
    end

    test "unresolved violation has nil resolved_by_id and resolved_at" do
      violation = PoliciesFixtures.policy_violation_fixture()

      assert violation.resolved == false
      assert is_nil(violation.resolved_by_id)
      assert is_nil(violation.resolved_at)
    end
  end

  describe "fixture and database persistence" do
    test "creates a violation with default attributes" do
      violation = PoliciesFixtures.policy_violation_fixture()

      assert violation.id
      assert violation.workspace_id
      assert violation.agent_event_id
      assert violation.policy_rule_id
      assert violation.action_taken == :flagged
      assert violation.severity == :medium
      assert violation.resolved == false
    end

    test "creates a violation with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      violation =
        PoliciesFixtures.policy_violation_fixture(%{
          workspace_id: workspace.id,
          action_taken: :blocked,
          severity: :critical
        })

      assert violation.action_taken == :blocked
      assert violation.severity == :critical
    end

    test "reloaded violation matches inserted data" do
      violation = PoliciesFixtures.policy_violation_fixture()
      reloaded = Repo.get!(PolicyViolation, violation.id)

      assert reloaded.action_taken == violation.action_taken
      assert reloaded.severity == violation.severity
      assert reloaded.workspace_id == violation.workspace_id
    end

    test "violation cannot be created without valid agent_event_id (FK)" do
      workspace = AccountsFixtures.workspace_fixture()
      rule = PoliciesFixtures.policy_rule_fixture(%{workspace_id: workspace.id})

      attrs = PoliciesFixtures.valid_policy_violation_attributes()

      assert {:error, changeset} =
               %PolicyViolation{
                 workspace_id: workspace.id,
                 agent_event_id: Ecto.UUID.generate(),
                 policy_rule_id: rule.id
               }
               |> PolicyViolation.changeset(attrs)
               |> Repo.insert()

      assert %{agent_event_id: ["does not exist"]} = errors_on(changeset)
    end

    test "violation cannot be created without valid policy_rule_id (FK)" do
      workspace = AccountsFixtures.workspace_fixture()
      event = GatewayFixtures.agent_event_fixture(%{workspace_id: workspace.id})

      attrs = PoliciesFixtures.valid_policy_violation_attributes()

      assert {:error, changeset} =
               %PolicyViolation{
                 workspace_id: workspace.id,
                 agent_event_id: event.id,
                 policy_rule_id: Ecto.UUID.generate()
               }
               |> PolicyViolation.changeset(attrs)
               |> Repo.insert()

      assert %{policy_rule_id: ["does not exist"]} = errors_on(changeset)
    end
  end
end
