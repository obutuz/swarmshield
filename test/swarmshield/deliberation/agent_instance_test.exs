defmodule Swarmshield.Deliberation.AgentInstanceTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Deliberation.AgentInstance
  alias Swarmshield.DeliberationFixtures

  describe "changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = DeliberationFixtures.valid_agent_instance_attributes()
      workspace = AccountsFixtures.workspace_fixture()
      session = DeliberationFixtures.analysis_session_fixture(%{workspace_id: workspace.id})
      definition = DeliberationFixtures.agent_definition_fixture(%{workspace_id: workspace.id})

      changeset =
        AgentInstance.changeset(
          %AgentInstance{
            analysis_session_id: session.id,
            agent_definition_id: definition.id
          },
          attrs
        )

      assert changeset.valid?
    end

    test "requires status" do
      attrs = DeliberationFixtures.valid_agent_instance_attributes(%{status: nil})
      changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

      refute changeset.valid?
      assert %{status: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts all valid statuses" do
      for status <- [:pending, :running, :completed, :failed, :timed_out] do
        attrs = DeliberationFixtures.valid_agent_instance_attributes(%{status: status})
        changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

        assert changeset.valid?, "Expected status #{status} to be valid"
      end
    end

    test "rejects invalid status" do
      attrs = DeliberationFixtures.valid_agent_instance_attributes(%{status: :invalid})
      changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

      refute changeset.valid?
      assert %{status: [_msg]} = errors_on(changeset)
    end

    test "accepts all valid votes" do
      for vote <- [:allow, :flag, :block] do
        attrs = DeliberationFixtures.valid_agent_instance_attributes(%{vote: vote})
        changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

        assert changeset.valid?, "Expected vote #{vote} to be valid"
      end
    end

    test "rejects invalid vote" do
      attrs = DeliberationFixtures.valid_agent_instance_attributes(%{vote: :invalid})
      changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

      refute changeset.valid?
      assert %{vote: [_msg]} = errors_on(changeset)
    end

    test "vote nil is valid before voting phase" do
      attrs = DeliberationFixtures.valid_agent_instance_attributes()
      changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :vote) == nil
    end

    test "status defaults to :pending" do
      attrs = DeliberationFixtures.valid_agent_instance_attributes()
      changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

      assert Ecto.Changeset.get_field(changeset, :status) == :pending
    end

    test "tokens_used defaults to 0" do
      changeset = AgentInstance.changeset(%AgentInstance{}, %{})
      assert Ecto.Changeset.get_field(changeset, :tokens_used) == 0
    end

    test "cost_cents defaults to 0" do
      changeset = AgentInstance.changeset(%AgentInstance{}, %{})
      assert Ecto.Changeset.get_field(changeset, :cost_cents) == 0
    end
  end

  describe "confidence validation" do
    test "confidence nil is valid before analysis completes" do
      attrs = DeliberationFixtures.valid_agent_instance_attributes()
      changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :confidence) == nil
    end

    test "confidence exactly 0.0 is valid" do
      attrs = DeliberationFixtures.valid_agent_instance_attributes(%{confidence: 0.0})
      changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

      assert changeset.valid?
    end

    test "confidence exactly 1.0 is valid" do
      attrs = DeliberationFixtures.valid_agent_instance_attributes(%{confidence: 1.0})
      changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

      assert changeset.valid?
    end

    test "confidence 1.01 is rejected" do
      attrs = DeliberationFixtures.valid_agent_instance_attributes(%{confidence: 1.01})
      changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

      refute changeset.valid?
      assert %{confidence: [msg]} = errors_on(changeset)
      assert msg =~ "less than or equal to 1.0"
    end

    test "confidence -0.1 is rejected" do
      attrs = DeliberationFixtures.valid_agent_instance_attributes(%{confidence: -0.1})
      changeset = AgentInstance.changeset(%AgentInstance{}, attrs)

      refute changeset.valid?
      assert %{confidence: [msg]} = errors_on(changeset)
      assert msg =~ "greater than or equal to 0.0"
    end
  end

  describe "fixture and database persistence" do
    test "creates an agent instance with default attributes" do
      instance = DeliberationFixtures.agent_instance_fixture()

      assert instance.id
      assert instance.analysis_session_id
      assert instance.agent_definition_id
      assert instance.status == :pending
      assert instance.role == "security_analyst"
      assert instance.tokens_used == 0
      assert instance.cost_cents == 0
      assert is_nil(instance.vote)
      assert is_nil(instance.confidence)
    end

    test "creates an agent instance with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      instance =
        DeliberationFixtures.agent_instance_fixture(%{
          workspace_id: workspace.id,
          role: "ethics_reviewer",
          status: :running,
          vote: :flag,
          confidence: 0.75
        })

      assert instance.role == "ethics_reviewer"
      assert instance.status == :running
      assert instance.vote == :flag
      assert instance.confidence == 0.75
    end

    test "role is copied from agent_definition on creation" do
      workspace = AccountsFixtures.workspace_fixture()

      definition =
        DeliberationFixtures.agent_definition_fixture(%{
          workspace_id: workspace.id,
          role: "compliance_officer"
        })

      instance =
        DeliberationFixtures.agent_instance_fixture(%{
          workspace_id: workspace.id,
          agent_definition_id: definition.id,
          role: "compliance_officer"
        })

      assert instance.role == "compliance_officer"
    end

    test "reloaded instance matches inserted data" do
      instance = DeliberationFixtures.agent_instance_fixture()
      reloaded = Repo.get!(AgentInstance, instance.id)

      assert reloaded.status == instance.status
      assert reloaded.role == instance.role
      assert reloaded.analysis_session_id == instance.analysis_session_id
    end
  end
end
