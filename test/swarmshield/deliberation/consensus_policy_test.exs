defmodule Swarmshield.Deliberation.ConsensusPolicyTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Deliberation.ConsensusPolicy
  alias Swarmshield.DeliberationFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = DeliberationFixtures.valid_consensus_policy_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{workspace_id: workspace.id}, attrs)

      assert changeset.valid?
    end

    test "requires name" do
      attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{name: nil})
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires strategy" do
      attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{strategy: nil})
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      refute changeset.valid?
      assert %{strategy: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name max length" do
      long_name = String.duplicate("a", 256)
      attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{name: long_name})
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      refute changeset.valid?
      assert %{name: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 255"
    end

    test "validates description max length" do
      long_desc = String.duplicate("a", 2001)
      attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{description: long_desc})
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      refute changeset.valid?
      assert %{description: [msg]} = errors_on(changeset)
      assert msg =~ "should be at most 2000"
    end

    test "accepts all valid strategies" do
      for strategy <- [:majority, :supermajority, :unanimous, :weighted] do
        attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{strategy: strategy})
        changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

        assert changeset.valid?, "Expected strategy #{strategy} to be valid"
      end
    end

    test "rejects invalid strategy" do
      attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{strategy: :invalid})
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      refute changeset.valid?
      assert %{strategy: [_msg]} = errors_on(changeset)
    end

    test "enabled defaults to true" do
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, %{})
      assert Ecto.Changeset.get_field(changeset, :enabled) == true
    end

    test "weights defaults to empty map" do
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, %{})
      assert Ecto.Changeset.get_field(changeset, :weights) == %{}
    end

    test "require_unanimous_on accepts empty array" do
      attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{require_unanimous_on: []})
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      assert changeset.valid?
    end

    test "require_unanimous_on accepts string values" do
      attrs =
        DeliberationFixtures.valid_consensus_policy_attributes(%{
          require_unanimous_on: ["block", "escalate"]
        })

      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      assert changeset.valid?
    end

    test "weights map accepts string keys (agent role names)" do
      attrs =
        DeliberationFixtures.valid_consensus_policy_attributes(%{
          weights: %{
            "security_analyst" => 2.0,
            "ethics_reviewer" => 1.5,
            "compliance_officer" => 1.0
          }
        })

      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      assert changeset.valid?
    end
  end

  describe "threshold validation" do
    test "threshold exactly 0.0 is valid" do
      attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{threshold: 0.0})
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      assert changeset.valid?
    end

    test "threshold exactly 1.0 is valid" do
      attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{threshold: 1.0})
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      assert changeset.valid?
    end

    test "threshold 1.01 is rejected" do
      attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{threshold: 1.01})
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      refute changeset.valid?
      assert %{threshold: [msg]} = errors_on(changeset)
      assert msg =~ "less than or equal to 1.0"
    end

    test "threshold -0.1 is rejected" do
      attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{threshold: -0.1})
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      refute changeset.valid?
      assert %{threshold: [msg]} = errors_on(changeset)
      assert msg =~ "greater than or equal to 0.0"
    end
  end

  describe "weights validation" do
    test "positive weight values are valid" do
      attrs =
        DeliberationFixtures.valid_consensus_policy_attributes(%{
          weights: %{"role_a" => 1.0, "role_b" => 2.5}
        })

      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      assert changeset.valid?
    end

    test "negative weight value is rejected" do
      attrs =
        DeliberationFixtures.valid_consensus_policy_attributes(%{
          weights: %{"role_a" => -1.0}
        })

      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      refute changeset.valid?
      assert %{weights: [msg]} = errors_on(changeset)
      assert msg =~ "positive numbers"
    end

    test "zero weight value is rejected" do
      attrs =
        DeliberationFixtures.valid_consensus_policy_attributes(%{
          weights: %{"role_a" => 0}
        })

      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      refute changeset.valid?
      assert %{weights: [msg]} = errors_on(changeset)
      assert msg =~ "positive numbers"
    end

    test "empty weights map is valid" do
      attrs = DeliberationFixtures.valid_consensus_policy_attributes(%{weights: %{}})
      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      assert changeset.valid?
    end

    test "integer weight values are valid" do
      attrs =
        DeliberationFixtures.valid_consensus_policy_attributes(%{
          weights: %{"role_a" => 1, "role_b" => 3}
        })

      changeset = ConsensusPolicy.changeset(%ConsensusPolicy{}, attrs)

      assert changeset.valid?
    end
  end

  describe "fixture and database persistence" do
    test "creates a consensus policy with default attributes" do
      policy = DeliberationFixtures.consensus_policy_fixture()

      assert policy.id
      assert policy.workspace_id
      assert policy.name
      assert policy.strategy == :majority
      assert policy.threshold == 0.5
      assert policy.weights == %{}
      assert policy.require_unanimous_on == []
      assert policy.enabled == true
    end

    test "creates a consensus policy with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      policy =
        DeliberationFixtures.consensus_policy_fixture(%{
          workspace_id: workspace.id,
          strategy: :supermajority,
          threshold: 0.67,
          weights: %{"analyst" => 2.0}
        })

      assert policy.strategy == :supermajority
      assert policy.threshold == 0.67
      assert policy.weights == %{"analyst" => 2.0}
    end

    test "reloaded policy matches inserted data" do
      policy = DeliberationFixtures.consensus_policy_fixture()
      reloaded = Repo.get!(ConsensusPolicy, policy.id)

      assert reloaded.name == policy.name
      assert reloaded.strategy == policy.strategy
      assert reloaded.threshold == policy.threshold
    end
  end
end
