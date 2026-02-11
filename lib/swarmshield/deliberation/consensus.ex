defmodule Swarmshield.Deliberation.Consensus do
  @moduledoc """
  Pure-function voting strategies for reaching verdicts in deliberation sessions.

  All consensus parameters come from database ConsensusPolicy records.
  Zero hardcoded consensus parameters.
  """

  alias Swarmshield.Deliberation.ConsensusPolicy

  @valid_votes [:allow, :flag, :block]

  @type vote :: %{
          agent_instance_id: binary(),
          vote: :allow | :flag | :block | nil,
          confidence: float() | nil,
          role: String.t()
        }

  @type consensus_result ::
          {:consensus, :allow | :flag | :block, map()}
          | {:no_consensus, map()}

  @spec evaluate([vote()], ConsensusPolicy.t()) :: consensus_result()
  def evaluate(votes, %ConsensusPolicy{strategy: :majority} = policy) do
    votes
    |> cast_votes()
    |> evaluate_majority(policy)
  end

  def evaluate(votes, %ConsensusPolicy{strategy: :supermajority} = policy) do
    votes
    |> cast_votes()
    |> evaluate_supermajority(policy)
  end

  def evaluate(votes, %ConsensusPolicy{strategy: :unanimous} = policy) do
    votes
    |> cast_votes()
    |> evaluate_unanimous(policy)
  end

  def evaluate(votes, %ConsensusPolicy{strategy: :weighted} = policy) do
    votes
    |> cast_votes()
    |> evaluate_weighted(policy)
  end

  @spec vote_breakdown([vote()]) :: %{
          allow: non_neg_integer(),
          flag: non_neg_integer(),
          block: non_neg_integer(),
          abstain: non_neg_integer()
        }
  def vote_breakdown(votes) do
    votes
    |> Enum.reduce(%{allow: 0, flag: 0, block: 0, abstain: 0}, fn
      %{vote: vote}, acc when vote in @valid_votes ->
        Map.update!(acc, vote, &(&1 + 1))

      %{vote: nil}, acc ->
        Map.update!(acc, :abstain, &(&1 + 1))

      _other, acc ->
        Map.update!(acc, :abstain, &(&1 + 1))
    end)
  end

  @spec confidence_score([vote()]) :: float()
  def confidence_score([]), do: 0.0

  def confidence_score(votes) do
    {sum, count} =
      Enum.reduce(votes, {0.0, 0}, fn
        %{confidence: c}, {sum, count} when is_number(c) ->
          {sum + c, count + 1}

        _vote, acc ->
          acc
      end)

    case count do
      0 -> 0.0
      n -> sum / n
    end
  end

  @spec dissenting_opinions([vote()], :allow | :flag | :block) :: [vote()]
  def dissenting_opinions(votes, winning_decision) when winning_decision in @valid_votes do
    Enum.filter(votes, fn
      %{vote: vote} when vote in @valid_votes -> vote != winning_decision
      _abstained -> false
    end)
  end

  # Private: filter to only valid votes (non-nil, in allowlist)
  defp cast_votes(votes) do
    Enum.filter(votes, fn
      %{vote: vote} when vote in @valid_votes -> true
      _other -> false
    end)
  end

  defp evaluate_majority([], _policy) do
    {:no_consensus, build_details([], :majority)}
  end

  defp evaluate_majority(valid_votes, _policy) do
    total = length(valid_votes)
    {decision, count} = leading_vote(valid_votes)
    ratio = count / total

    case ratio > 0.5 do
      true ->
        {:consensus, decision, build_details(valid_votes, :majority, decision, ratio)}

      false ->
        {:no_consensus, build_details(valid_votes, :majority)}
    end
  end

  defp evaluate_supermajority([], _policy) do
    {:no_consensus, build_details([], :supermajority)}
  end

  defp evaluate_supermajority(valid_votes, %ConsensusPolicy{threshold: threshold}) do
    total = length(valid_votes)
    {decision, count} = leading_vote(valid_votes)
    ratio = count / total

    case ratio >= threshold do
      true ->
        {:consensus, decision, build_details(valid_votes, :supermajority, decision, ratio)}

      false ->
        {:no_consensus, build_details(valid_votes, :supermajority)}
    end
  end

  defp evaluate_unanimous([], _policy) do
    {:no_consensus, build_details([], :unanimous)}
  end

  defp evaluate_unanimous(valid_votes, _policy) do
    votes_by_decision = Enum.group_by(valid_votes, & &1.vote)

    case map_size(votes_by_decision) do
      1 ->
        [{decision, _}] = Enum.to_list(votes_by_decision)
        {:consensus, decision, build_details(valid_votes, :unanimous, decision, 1.0)}

      _multiple ->
        {:no_consensus, build_details(valid_votes, :unanimous)}
    end
  end

  defp evaluate_weighted([], _policy) do
    {:no_consensus, build_details([], :weighted)}
  end

  defp evaluate_weighted(valid_votes, %ConsensusPolicy{weights: weights, threshold: threshold}) do
    safe_weights = sanitize_weights(weights)

    weighted_totals =
      Enum.reduce(valid_votes, %{}, fn %{vote: vote, role: role}, acc ->
        weight = Map.get(safe_weights, role, 1.0)
        Map.update(acc, vote, weight, &(&1 + weight))
      end)

    total_weight =
      weighted_totals
      |> Map.values()
      |> Enum.sum()

    case total_weight == 0 do
      true ->
        {:no_consensus, build_details(valid_votes, :weighted)}

      false ->
        {decision, decision_weight} =
          Enum.max_by(weighted_totals, fn {_vote, weight} -> weight end)

        ratio = decision_weight / total_weight

        case ratio >= threshold do
          true ->
            {:consensus, decision, build_details(valid_votes, :weighted, decision, ratio)}

          false ->
            {:no_consensus, build_details(valid_votes, :weighted)}
        end
    end
  end

  defp sanitize_weights(nil), do: %{}

  defp sanitize_weights(weights) when is_map(weights) do
    Map.new(weights, fn
      {role, weight} when is_number(weight) and weight >= 0 -> {role, weight}
      {role, _negative_or_invalid} -> {role, 0.0}
    end)
  end

  defp leading_vote(valid_votes) do
    valid_votes
    |> Enum.frequencies_by(& &1.vote)
    |> Enum.max_by(fn {_vote, count} -> count end)
  end

  defp build_details(valid_votes, strategy) do
    %{
      strategy: strategy,
      total_valid_votes: length(valid_votes),
      breakdown: vote_breakdown_from_valid(valid_votes)
    }
  end

  defp build_details(valid_votes, strategy, decision, ratio) do
    %{
      strategy: strategy,
      decision: decision,
      ratio: ratio,
      total_valid_votes: length(valid_votes),
      breakdown: vote_breakdown_from_valid(valid_votes)
    }
  end

  defp vote_breakdown_from_valid(valid_votes) do
    Enum.reduce(valid_votes, %{allow: 0, flag: 0, block: 0}, fn
      %{vote: vote}, acc when vote in @valid_votes ->
        Map.update!(acc, vote, &(&1 + 1))

      _other, acc ->
        acc
    end)
  end
end
