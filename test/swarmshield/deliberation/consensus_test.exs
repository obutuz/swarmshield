defmodule Swarmshield.Deliberation.ConsensusTest do
  use ExUnit.Case, async: true

  alias Swarmshield.Deliberation.Consensus
  alias Swarmshield.Deliberation.ConsensusPolicy

  defp policy(strategy, opts \\ []) do
    %ConsensusPolicy{
      id: Ecto.UUID.generate(),
      strategy: strategy,
      threshold: Keyword.get(opts, :threshold, 0.5),
      weights: Keyword.get(opts, :weights, %{})
    }
  end

  defp vote(agent_id, decision, confidence \\ 0.9, role \\ "analyst") do
    %{
      agent_instance_id: agent_id,
      vote: decision,
      confidence: confidence,
      role: role
    }
  end

  describe "evaluate/2 - majority strategy" do
    test "clear majority reaches consensus" do
      votes = [
        vote("a1", :allow),
        vote("a2", :allow),
        vote("a3", :block)
      ]

      assert {:consensus, :allow, details} = Consensus.evaluate(votes, policy(:majority))
      assert details.strategy == :majority
      assert details.decision == :allow
      assert details.ratio > 0.5
    end

    test "50/50 tie does NOT reach majority" do
      votes = [
        vote("a1", :allow),
        vote("a2", :block)
      ]

      assert {:no_consensus, details} = Consensus.evaluate(votes, policy(:majority))
      assert details.strategy == :majority
      assert details.total_valid_votes == 2
    end

    test "single voter always reaches consensus" do
      votes = [vote("a1", :flag)]

      assert {:consensus, :flag, details} = Consensus.evaluate(votes, policy(:majority))
      assert details.ratio == 1.0
    end

    test "nil votes are excluded from majority calculation" do
      votes = [
        vote("a1", :allow),
        vote("a2", :allow),
        vote("a3", nil),
        vote("a4", nil)
      ]

      assert {:consensus, :allow, details} = Consensus.evaluate(votes, policy(:majority))
      assert details.total_valid_votes == 2
    end

    test "all agents abstain results in no_consensus" do
      votes = [
        vote("a1", nil),
        vote("a2", nil),
        vote("a3", nil)
      ]

      assert {:no_consensus, details} = Consensus.evaluate(votes, policy(:majority))
      assert details.total_valid_votes == 0
    end

    test "empty votes list results in no_consensus" do
      assert {:no_consensus, _details} = Consensus.evaluate([], policy(:majority))
    end
  end

  describe "evaluate/2 - supermajority strategy" do
    test "meets threshold with supermajority" do
      votes = [
        vote("a1", :block),
        vote("a2", :block),
        vote("a3", :block),
        vote("a4", :allow)
      ]

      assert {:consensus, :block, details} =
               Consensus.evaluate(votes, policy(:supermajority, threshold: 0.67))

      assert details.ratio == 0.75
    end

    test "exactly 2/3 at 0.67 threshold does NOT reach supermajority" do
      votes = [
        vote("a1", :allow),
        vote("a2", :allow),
        vote("a3", :block)
      ]

      ratio = 2 / 3

      assert {:no_consensus, _details} =
               Consensus.evaluate(votes, policy(:supermajority, threshold: 0.67))

      assert ratio < 0.67
    end

    test "exactly at threshold reaches supermajority" do
      votes = [
        vote("a1", :flag),
        vote("a2", :flag),
        vote("a3", :flag),
        vote("a4", :allow)
      ]

      assert {:consensus, :flag, details} =
               Consensus.evaluate(votes, policy(:supermajority, threshold: 0.75))

      assert details.ratio == 0.75
    end

    test "all abstain results in no_consensus for supermajority" do
      votes = [vote("a1", nil), vote("a2", nil)]

      assert {:no_consensus, _details} =
               Consensus.evaluate(votes, policy(:supermajority, threshold: 0.67))
    end
  end

  describe "evaluate/2 - unanimous strategy" do
    test "all agents agree reaches unanimous consensus" do
      votes = [
        vote("a1", :block),
        vote("a2", :block),
        vote("a3", :block)
      ]

      assert {:consensus, :block, details} = Consensus.evaluate(votes, policy(:unanimous))
      assert details.ratio == 1.0
    end

    test "single dissenter breaks unanimity" do
      votes = [
        vote("a1", :allow),
        vote("a2", :allow),
        vote("a3", :flag)
      ]

      assert {:no_consensus, _details} = Consensus.evaluate(votes, policy(:unanimous))
    end

    test "nil votes excluded from unanimity check" do
      votes = [
        vote("a1", :allow),
        vote("a2", nil),
        vote("a3", :allow)
      ]

      assert {:consensus, :allow, details} = Consensus.evaluate(votes, policy(:unanimous))
      assert details.total_valid_votes == 2
    end

    test "single voter unanimous" do
      votes = [vote("a1", :block)]

      assert {:consensus, :block, _details} = Consensus.evaluate(votes, policy(:unanimous))
    end
  end

  describe "evaluate/2 - weighted strategy" do
    test "higher-weighted role drives decision" do
      votes = [
        vote("a1", :block, 0.9, "lead_analyst"),
        vote("a2", :allow, 0.8, "junior")
      ]

      weights = %{"lead_analyst" => 3.0, "junior" => 1.0}

      assert {:consensus, :block, details} =
               Consensus.evaluate(votes, policy(:weighted, threshold: 0.5, weights: weights))

      assert details.decision == :block
      assert details.ratio == 0.75
    end

    test "zero-weight agents effectively excluded" do
      votes = [
        vote("a1", :allow, 0.9, "important"),
        vote("a2", :block, 0.9, "excluded"),
        vote("a3", :block, 0.9, "excluded")
      ]

      weights = %{"important" => 2.0, "excluded" => 0.0}

      assert {:consensus, :allow, details} =
               Consensus.evaluate(votes, policy(:weighted, threshold: 0.5, weights: weights))

      assert details.decision == :allow
    end

    test "role without explicit weight gets default 1.0" do
      votes = [
        vote("a1", :flag, 0.9, "unlisted_role"),
        vote("a2", :flag, 0.9, "another_unlisted")
      ]

      weights = %{"lead_analyst" => 3.0}

      assert {:consensus, :flag, _details} =
               Consensus.evaluate(votes, policy(:weighted, threshold: 0.5, weights: weights))
    end

    test "weighted does not reach threshold" do
      votes = [
        vote("a1", :allow, 0.9, "analyst"),
        vote("a2", :block, 0.9, "analyst"),
        vote("a3", :flag, 0.9, "analyst")
      ]

      weights = %{"analyst" => 1.0}

      assert {:no_consensus, _details} =
               Consensus.evaluate(votes, policy(:weighted, threshold: 0.5, weights: weights))
    end

    test "all zero-weight agents results in no_consensus" do
      votes = [
        vote("a1", :allow, 0.9, "excluded"),
        vote("a2", :block, 0.9, "excluded")
      ]

      weights = %{"excluded" => 0.0}

      assert {:no_consensus, _details} =
               Consensus.evaluate(votes, policy(:weighted, threshold: 0.5, weights: weights))
    end
  end

  describe "vote_breakdown/1" do
    test "counts each vote category" do
      votes = [
        vote("a1", :allow),
        vote("a2", :allow),
        vote("a3", :flag),
        vote("a4", :block),
        vote("a5", nil)
      ]

      assert %{allow: 2, flag: 1, block: 1, abstain: 1} = Consensus.vote_breakdown(votes)
    end

    test "all nil votes count as abstain" do
      votes = [vote("a1", nil), vote("a2", nil)]

      assert %{allow: 0, flag: 0, block: 0, abstain: 2} = Consensus.vote_breakdown(votes)
    end

    test "empty list returns zero counts" do
      assert %{allow: 0, flag: 0, block: 0, abstain: 0} = Consensus.vote_breakdown([])
    end

    test "invalid vote values count as abstain" do
      votes = [%{agent_instance_id: "a1", vote: :invalid, confidence: 0.5, role: "analyst"}]

      assert %{abstain: 1} = Consensus.vote_breakdown(votes)
    end
  end

  describe "confidence_score/1" do
    test "averages non-nil confidence values" do
      votes = [
        vote("a1", :allow, 0.8),
        vote("a2", :allow, 0.6),
        vote("a3", :allow, 1.0)
      ]

      assert_in_delta Consensus.confidence_score(votes), 0.8, 0.001
    end

    test "ignores nil confidence" do
      votes = [
        vote("a1", :allow, 0.9),
        vote("a2", :allow, nil)
      ]

      assert_in_delta Consensus.confidence_score(votes), 0.9, 0.001
    end

    test "empty list returns 0.0" do
      assert Consensus.confidence_score([]) == 0.0
    end

    test "all nil confidence returns 0.0" do
      votes = [
        vote("a1", :allow, nil),
        vote("a2", :allow, nil)
      ]

      assert Consensus.confidence_score(votes) == 0.0
    end
  end

  describe "dissenting_opinions/2" do
    test "returns votes that disagree with winning decision" do
      votes = [
        vote("a1", :allow),
        vote("a2", :block),
        vote("a3", :allow),
        vote("a4", :flag)
      ]

      dissenters = Consensus.dissenting_opinions(votes, :allow)

      assert length(dissenters) == 2
      assert Enum.all?(dissenters, fn %{vote: v} -> v != :allow end)
    end

    test "excludes abstainers from dissenters" do
      votes = [
        vote("a1", :allow),
        vote("a2", nil),
        vote("a3", :block)
      ]

      dissenters = Consensus.dissenting_opinions(votes, :allow)

      assert length(dissenters) == 1
      assert hd(dissenters).vote == :block
    end

    test "no dissenters when unanimous" do
      votes = [
        vote("a1", :allow),
        vote("a2", :allow)
      ]

      assert Consensus.dissenting_opinions(votes, :allow) == []
    end

    test "empty votes returns empty list" do
      assert Consensus.dissenting_opinions([], :allow) == []
    end
  end
end
