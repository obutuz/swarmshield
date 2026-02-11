defmodule Swarmshield.Policies.Rules.PatternMatch do
  @moduledoc """
  Implements pattern matching evaluation using cached detection rules.

  Checks event content against regex patterns and keyword lists from
  database-stored DetectionRule records. All patterns loaded from DB - zero
  hardcoded patterns.

  Security:
  - Regex execution uses explicit timeout (Task with 100ms timeout) to prevent ReDoS
  - Pattern match results do NOT include matched content snippets
  """

  require Logger

  alias Swarmshield.Policies.PolicyCache

  @regex_timeout_ms 100

  @doc """
  Evaluates an event against detection rules referenced by a pattern_match policy rule.

  Rule config format:
  ```
  %{"detection_rule_ids" => [uuid, ...]}
  ```

  Returns `{:ok, :no_match}` or `{:violation, %{matched_patterns: [...], detection_rule_ids: [...]}}`.
  """
  def evaluate(event, rule) do
    config = rule.config
    detection_rule_ids = config["detection_rule_ids"] || config[:detection_rule_ids] || []

    workspace_id = event.workspace_id
    content = event.content || ""

    # Load detection rules from cache
    cached_detection_rules = PolicyCache.get_detection_rules(workspace_id)

    # Filter to only the detection rules referenced by this policy rule
    applicable_rules =
      Enum.filter(cached_detection_rules, fn dr ->
        dr.id in detection_rule_ids and dr.enabled
      end)

    matches = evaluate_detection_rules(applicable_rules, content)

    case matches do
      [] ->
        {:ok, :no_match}

      matches ->
        {:violation,
         %{
           matched_patterns: Enum.map(matches, & &1.name),
           detection_rule_ids: Enum.map(matches, & &1.id)
         }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp evaluate_detection_rules(rules, content) do
    Enum.filter(rules, fn rule ->
      match_detection_rule(rule, content)
    end)
  end

  # Dispatch based on detection_type via pattern matching
  defp match_detection_rule(%{detection_type: :regex, pattern: pattern}, content)
       when is_binary(pattern) and pattern != "" do
    match_regex_with_timeout(pattern, content)
  end

  defp match_detection_rule(%{detection_type: :keyword, keywords: keywords}, content)
       when is_list(keywords) do
    match_keywords(keywords, content)
  end

  defp match_detection_rule(%{detection_type: :semantic}, _content) do
    # Semantic detection requires LLM - not evaluated in the fast path
    false
  end

  defp match_detection_rule(rule, _content) do
    Logger.warning("[PatternMatch] Detection rule #{rule.id} has invalid configuration, skipping")
    false
  end

  defp match_regex_with_timeout(pattern, content) do
    task =
      Task.async(fn ->
        case Regex.compile(pattern, "i") do
          {:ok, regex} -> Regex.match?(regex, content)
          {:error, _reason} -> false
        end
      end)

    case Task.yield(task, @regex_timeout_ms) || Task.shutdown(task) do
      {:ok, result} ->
        result

      nil ->
        Logger.warning(
          "[PatternMatch] Regex timeout for pattern: #{String.slice(pattern, 0, 50)}"
        )

        false
    end
  end

  defp match_keywords(keywords, content) do
    downcased_content = String.downcase(content)

    Enum.any?(keywords, fn keyword ->
      String.contains?(downcased_content, String.downcase(keyword))
    end)
  end
end
