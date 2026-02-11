defmodule Swarmshield.Deliberation.VerdictTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.AccountsFixtures
  alias Swarmshield.Deliberation.Verdict
  alias Swarmshield.DeliberationFixtures

  describe "create_changeset/2" do
    test "valid attributes produce a valid changeset" do
      attrs = DeliberationFixtures.valid_verdict_attributes()
      session = DeliberationFixtures.analysis_session_fixture()

      changeset =
        Verdict.create_changeset(
          %Verdict{analysis_session_id: session.id},
          attrs
        )

      assert changeset.valid?
    end

    test "requires decision" do
      attrs = DeliberationFixtures.valid_verdict_attributes(%{decision: nil})
      changeset = Verdict.create_changeset(%Verdict{}, attrs)

      refute changeset.valid?
      assert %{decision: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires confidence" do
      attrs = DeliberationFixtures.valid_verdict_attributes(%{confidence: nil})
      changeset = Verdict.create_changeset(%Verdict{}, attrs)

      refute changeset.valid?
      assert %{confidence: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires reasoning" do
      attrs = DeliberationFixtures.valid_verdict_attributes(%{reasoning: nil})
      changeset = Verdict.create_changeset(%Verdict{}, attrs)

      refute changeset.valid?
      assert %{reasoning: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts all valid decisions" do
      for decision <- [:allow, :flag, :block, :escalate] do
        attrs = DeliberationFixtures.valid_verdict_attributes(%{decision: decision})
        changeset = Verdict.create_changeset(%Verdict{}, attrs)

        assert changeset.valid?, "Expected decision #{decision} to be valid"
      end
    end

    test "rejects invalid decision" do
      attrs = DeliberationFixtures.valid_verdict_attributes(%{decision: :invalid})
      changeset = Verdict.create_changeset(%Verdict{}, attrs)

      refute changeset.valid?
      assert %{decision: [_msg]} = errors_on(changeset)
    end

    test "dissenting_opinions defaults to empty array" do
      changeset = Verdict.create_changeset(%Verdict{}, %{})
      assert Ecto.Changeset.get_field(changeset, :dissenting_opinions) == []
    end

    test "dissenting_opinions can be empty array" do
      attrs = DeliberationFixtures.valid_verdict_attributes(%{dissenting_opinions: []})
      changeset = Verdict.create_changeset(%Verdict{}, attrs)

      assert changeset.valid?
    end

    test "dissenting_opinions accepts maps with agent details" do
      opinions = [
        %{"agent_role" => "ethics_reviewer", "vote" => "block", "rationale" => "Privacy concern"},
        %{"agent_role" => "compliance_officer", "vote" => "flag", "rationale" => "Needs review"}
      ]

      attrs = DeliberationFixtures.valid_verdict_attributes(%{dissenting_opinions: opinions})
      session = DeliberationFixtures.analysis_session_fixture()

      {:ok, verdict} =
        %Verdict{analysis_session_id: session.id}
        |> Verdict.create_changeset(attrs)
        |> Repo.insert()

      assert length(verdict.dissenting_opinions) == 2
    end

    test "vote_breakdown defaults to empty map" do
      changeset = Verdict.create_changeset(%Verdict{}, %{})
      assert Ecto.Changeset.get_field(changeset, :vote_breakdown) == %{}
    end

    test "vote_breakdown stores vote counts" do
      breakdown = %{"allow" => 2, "flag" => 1, "block" => 0}
      attrs = DeliberationFixtures.valid_verdict_attributes(%{vote_breakdown: breakdown})
      session = DeliberationFixtures.analysis_session_fixture()

      {:ok, verdict} =
        %Verdict{analysis_session_id: session.id}
        |> Verdict.create_changeset(attrs)
        |> Repo.insert()

      assert verdict.vote_breakdown == breakdown
    end

    test "recommended_actions defaults to empty array" do
      changeset = Verdict.create_changeset(%Verdict{}, %{})
      assert Ecto.Changeset.get_field(changeset, :recommended_actions) == []
    end

    test "recommended_actions can be empty array" do
      attrs = DeliberationFixtures.valid_verdict_attributes(%{recommended_actions: []})
      changeset = Verdict.create_changeset(%Verdict{}, attrs)

      assert changeset.valid?
    end

    test "recommended_actions accepts string values" do
      actions = ["notify_admin", "quarantine_agent", "escalate_to_human"]
      attrs = DeliberationFixtures.valid_verdict_attributes(%{recommended_actions: actions})
      session = DeliberationFixtures.analysis_session_fixture()

      {:ok, verdict} =
        %Verdict{analysis_session_id: session.id}
        |> Verdict.create_changeset(attrs)
        |> Repo.insert()

      assert verdict.recommended_actions == actions
    end

    test "consensus_reached defaults to false" do
      changeset = Verdict.create_changeset(%Verdict{}, %{})
      assert Ecto.Changeset.get_field(changeset, :consensus_reached) == false
    end
  end

  describe "confidence validation" do
    test "confidence exactly 0.0 is valid" do
      attrs = DeliberationFixtures.valid_verdict_attributes(%{confidence: 0.0})
      changeset = Verdict.create_changeset(%Verdict{}, attrs)

      assert changeset.valid?
    end

    test "confidence exactly 1.0 is valid" do
      attrs = DeliberationFixtures.valid_verdict_attributes(%{confidence: 1.0})
      changeset = Verdict.create_changeset(%Verdict{}, attrs)

      assert changeset.valid?
    end

    test "confidence 1.01 is rejected" do
      attrs = DeliberationFixtures.valid_verdict_attributes(%{confidence: 1.01})
      changeset = Verdict.create_changeset(%Verdict{}, attrs)

      refute changeset.valid?
      assert %{confidence: [msg]} = errors_on(changeset)
      assert msg =~ "less than or equal to 1.0"
    end

    test "confidence -0.1 is rejected" do
      attrs = DeliberationFixtures.valid_verdict_attributes(%{confidence: -0.1})
      changeset = Verdict.create_changeset(%Verdict{}, attrs)

      refute changeset.valid?
      assert %{confidence: [msg]} = errors_on(changeset)
      assert msg =~ "greater than or equal to 0.0"
    end
  end

  describe "immutability" do
    test "Verdict module does not expose an update changeset" do
      refute function_exported?(Verdict, :changeset, 2)
    end

    test "only create_changeset is available" do
      assert function_exported?(Verdict, :create_changeset, 2)
    end
  end

  describe "one verdict per analysis session" do
    test "duplicate verdict for same session is rejected" do
      session = DeliberationFixtures.analysis_session_fixture()
      _verdict1 = DeliberationFixtures.verdict_fixture(%{analysis_session_id: session.id})

      attrs = DeliberationFixtures.valid_verdict_attributes(%{decision: :block, confidence: 0.9})

      {:error, changeset} =
        %Verdict{analysis_session_id: session.id}
        |> Verdict.create_changeset(attrs)
        |> Repo.insert()

      assert %{analysis_session_id: [msg]} = errors_on(changeset)
      assert msg =~ "already exists"
    end

    test "different sessions can each have a verdict" do
      workspace = AccountsFixtures.workspace_fixture()
      session1 = DeliberationFixtures.analysis_session_fixture(%{workspace_id: workspace.id})
      session2 = DeliberationFixtures.analysis_session_fixture(%{workspace_id: workspace.id})

      verdict1 = DeliberationFixtures.verdict_fixture(%{analysis_session_id: session1.id})
      verdict2 = DeliberationFixtures.verdict_fixture(%{analysis_session_id: session2.id})

      assert verdict1.analysis_session_id == session1.id
      assert verdict2.analysis_session_id == session2.id
    end
  end

  describe "FK cascade behavior" do
    test "deleting analysis session cascades to its verdict" do
      verdict = DeliberationFixtures.verdict_fixture()
      session = Repo.get!(Swarmshield.Deliberation.AnalysisSession, verdict.analysis_session_id)

      Repo.delete!(session)

      assert Repo.get(Verdict, verdict.id) == nil
    end
  end

  describe "fixture and database persistence" do
    test "creates a verdict with default attributes" do
      verdict = DeliberationFixtures.verdict_fixture()

      assert verdict.id
      assert verdict.analysis_session_id
      assert verdict.decision == :allow
      assert verdict.confidence == 0.85
      assert verdict.reasoning =~ "safe"
      assert verdict.dissenting_opinions == []
      assert verdict.vote_breakdown == %{"allow" => 3, "flag" => 0, "block" => 0}
      assert verdict.recommended_actions == []
      assert verdict.consensus_reached == true
      assert verdict.consensus_strategy_used == "majority"
    end

    test "creates a verdict with custom attributes" do
      workspace = AccountsFixtures.workspace_fixture()

      verdict =
        DeliberationFixtures.verdict_fixture(%{
          workspace_id: workspace.id,
          decision: :block,
          confidence: 0.95,
          reasoning: "Multiple agents detected prompt injection"
        })

      assert verdict.decision == :block
      assert verdict.confidence == 0.95
      assert verdict.reasoning =~ "prompt injection"
    end

    test "reloaded verdict matches inserted data" do
      verdict = DeliberationFixtures.verdict_fixture()
      reloaded = Repo.get!(Verdict, verdict.id)

      assert reloaded.decision == verdict.decision
      assert reloaded.confidence == verdict.confidence
      assert reloaded.reasoning == verdict.reasoning
      assert reloaded.consensus_reached == verdict.consensus_reached
    end
  end
end
