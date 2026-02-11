defmodule Swarmshield.Policies.PolicyEngine do
  @moduledoc """
  Pure-function module for evaluating agent events against cached policy rules.

  PolicyEngine reads rules from the ETS-backed PolicyCache and evaluates an
  event against them. It is pure - no side effects, no database writes.

  The evaluation flow:
  1. Load cached rules for the workspace
  2. Filter rules by applicability (event type, agent type)
  3. Evaluate rules in priority order (highest first)
  4. Short-circuit on first :block match
  5. Collect all :flag matches
  6. Return :allow if no rules match

  Returns: `{action, matched_rules, details_map}`
  """

  require Logger

  alias Swarmshield.Policies.PolicyCache
  alias Swarmshield.Policies.Rules.ListMatch
  alias Swarmshield.Policies.Rules.PatternMatch
  alias Swarmshield.Policies.Rules.PayloadSize
  alias Swarmshield.Policies.Rules.RateLimit

  @doc """
  Evaluates an agent event against cached policy rules for a workspace.

  Returns `{action, matched_rules, details}` where:
  - `action` is `:allow`, `:flag`, or `:block`
  - `matched_rules` is a list of `%{rule_id: id, rule_name: name, action: atom}`
  - `details` is a map with evaluation metadata

  ## Parameters
  - `event` - The `%AgentEvent{}` struct (or map with event fields)
  - `workspace_id` - The workspace UUID

  ## Examples

      iex> evaluate(%AgentEvent{event_type: :action, content: "hello"}, workspace_id)
      {:allow, [], %{evaluated_count: 0, block_count: 0, flag_count: 0, duration_us: 42}}
  """
  def evaluate(event, workspace_id) when is_binary(workspace_id) do
    start_time = System.monotonic_time(:microsecond)

    rules = PolicyCache.get_rules(workspace_id)

    {action, matched_rules, counts} =
      rules
      |> filter_applicable_rules(event)
      |> evaluate_rules(event, workspace_id)

    end_time = System.monotonic_time(:microsecond)
    duration_us = end_time - start_time

    details = Map.merge(counts, %{duration_us: duration_us})

    emit_telemetry(workspace_id, action, details)

    {action, matched_rules, details}
  end

  # ---------------------------------------------------------------------------
  # Rule filtering
  # ---------------------------------------------------------------------------

  defp filter_applicable_rules(rules, event) do
    Enum.filter(rules, fn rule ->
      applies_to_event_type?(rule, event) and applies_to_agent_type?(rule, event)
    end)
  end

  # Empty applies_to arrays means the rule applies to all types
  defp applies_to_event_type?(%{applies_to_event_types: []}, _event), do: true

  defp applies_to_event_type?(%{applies_to_event_types: types}, event) when is_list(types) do
    event_type = to_string(event.event_type)
    event_type in types
  end

  defp applies_to_event_type?(_rule, _event), do: true

  defp applies_to_agent_type?(%{applies_to_agent_types: []}, _event), do: true

  defp applies_to_agent_type?(%{applies_to_agent_types: types}, event) when is_list(types) do
    # Agent type comes from the registered agent, may be preloaded or in metadata
    agent_type =
      cond do
        is_map(event) and Map.has_key?(event, :registered_agent) and
            not is_nil(event.registered_agent) ->
          to_string(event.registered_agent.agent_type)

        is_map(event) and Map.has_key?(event, :agent_type) ->
          to_string(event.agent_type)

        true ->
          nil
      end

    is_nil(agent_type) or agent_type in types
  end

  defp applies_to_agent_type?(_rule, _event), do: true

  # ---------------------------------------------------------------------------
  # Rule evaluation - priority order, short-circuit on block
  # ---------------------------------------------------------------------------

  defp evaluate_rules(rules, event, workspace_id) do
    # Rules are already ordered by priority DESC from PolicyCache
    initial_state = {:allow, [], %{evaluated_count: 0, block_count: 0, flag_count: 0}}

    Enum.reduce_while(rules, initial_state, fn rule, acc ->
      process_rule_result(rule, acc, event, workspace_id)
    end)
    |> then(fn {action, matched, counts} ->
      {action, Enum.reverse(matched), counts}
    end)
  end

  defp process_rule_result(rule, {_current_action, matched, counts}, event, workspace_id) do
    counts = %{counts | evaluated_count: counts.evaluated_count + 1}

    case evaluate_single_rule(rule, event, workspace_id) do
      {:violation, rule_match} ->
        handle_violation(rule, rule_match, matched, counts)

      :no_violation ->
        current_action = if counts.flag_count > 0, do: :flag, else: :allow
        {:cont, {current_action, matched, counts}}
    end
  end

  defp handle_violation(%{action: :block} = _rule, rule_match, matched, counts) do
    counts = %{counts | block_count: counts.block_count + 1}
    {:halt, {:block, Enum.reverse([rule_match | matched]), counts}}
  end

  defp handle_violation(%{action: :flag} = _rule, rule_match, matched, counts) do
    counts = %{counts | flag_count: counts.flag_count + 1}
    {:cont, {:flag, [rule_match | matched], counts}}
  end

  defp handle_violation(_rule, rule_match, matched, counts) do
    counts = %{counts | flag_count: counts.flag_count + 1}
    {:cont, {:flag, [rule_match | matched], counts}}
  end

  defp evaluate_single_rule(rule, event, workspace_id) do
    rule_match = %{
      rule_id: rule.id,
      rule_name: rule.name,
      action: rule.action,
      rule_type: rule.rule_type
    }

    try do
      case do_evaluate_rule(rule, event, workspace_id) do
        {:violation, _details} -> {:violation, rule_match}
        _no_violation -> :no_violation
      end
    rescue
      e ->
        Logger.warning(
          "[PolicyEngine] Rule #{rule.name} (#{rule.id}) evaluation failed: #{Exception.message(e)}"
        )

        :no_violation
    end
  end

  # Dispatch to rule evaluator based on rule_type via pattern matching.
  # Each evaluator returns {:ok, _} or {:violation, details}.
  # We normalize to :no_violation or {:violation, details}.
  @spec do_evaluate_rule(map(), map(), binary()) :: :no_violation | {:violation, map()}
  defp do_evaluate_rule(%{rule_type: :rate_limit} = rule, event, _workspace_id) do
    normalize_result(RateLimit.evaluate(event, rule))
  end

  defp do_evaluate_rule(%{rule_type: :pattern_match} = rule, event, _workspace_id) do
    normalize_result(PatternMatch.evaluate(event, rule))
  end

  defp do_evaluate_rule(%{rule_type: :blocklist} = rule, event, _workspace_id) do
    normalize_result(ListMatch.evaluate(event, rule))
  end

  defp do_evaluate_rule(%{rule_type: :allowlist} = rule, event, _workspace_id) do
    normalize_result(ListMatch.evaluate(event, rule))
  end

  defp do_evaluate_rule(%{rule_type: :payload_size} = rule, event, _workspace_id) do
    normalize_result(PayloadSize.evaluate(event, rule))
  end

  defp do_evaluate_rule(%{rule_type: :custom}, _event, _workspace_id), do: :no_violation

  defp do_evaluate_rule(%{rule_type: unknown_type} = rule, _event, _workspace_id) do
    Logger.warning(
      "[PolicyEngine] Unknown rule_type #{inspect(unknown_type)} for rule #{rule.name} (#{rule.id}), skipping"
    )

    :no_violation
  end

  defp normalize_result({:ok, _}), do: :no_violation
  defp normalize_result({:violation, details}), do: {:violation, details}

  # ---------------------------------------------------------------------------
  # Telemetry
  # ---------------------------------------------------------------------------

  defp emit_telemetry(workspace_id, action, details) do
    :telemetry.execute(
      [:swarmshield, :policy_engine, :evaluate],
      %{duration_us: details.duration_us},
      %{
        workspace_id: workspace_id,
        action: action,
        evaluated_count: details.evaluated_count,
        block_count: details.block_count,
        flag_count: details.flag_count
      }
    )
  end
end
