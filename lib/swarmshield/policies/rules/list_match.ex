defmodule Swarmshield.Policies.Rules.ListMatch do
  @moduledoc """
  Implements blocklist and allowlist evaluation.

  Checks agent names, IPs, or content against configured lists from database
  rule config. Zero hardcoded block/allow lists.

  Security:
  - Field access uses strict whitelist - NEVER dynamically access arbitrary struct fields
  - Values with leading/trailing whitespace are trimmed before comparison
  - Case-insensitive matching for string values
  """

  require Logger

  # Strict whitelist of event fields that can be matched against
  @allowed_fields [:agent_name, :source_ip, :content, :event_type]

  @doc """
  Evaluates an event against a blocklist or allowlist rule.

  Rule config format:
  ```
  %{
    "list_type" => "blocklist" | "allowlist",
    "field" => "agent_name" | "source_ip" | "content" | "event_type",
    "values" => [string, ...]
  }
  ```

  Returns `{:ok, :passed}` or `{:violation, details}`.
  """
  def evaluate(event, rule) do
    config = rule.config

    list_type = config["list_type"] || config[:list_type]
    field = config["field"] || config[:field]
    values = config["values"] || config[:values] || []

    # Normalize values: trim whitespace, downcase for comparison
    normalized_values = Enum.map(values, &normalize_value/1)
    field_atom = safe_field_atom(field)
    field_value = extract_field_value(event, field_atom)

    evaluate_list(list_type, field_value, normalized_values)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Blocklist: violation if field value IS in the list
  defp evaluate_list("blocklist", nil, _values) do
    # nil field value for blocklist = nothing to block
    {:ok, :passed}
  end

  defp evaluate_list("blocklist", _field_value, []) do
    # Empty blocklist = nothing blocked
    {:ok, :passed}
  end

  defp evaluate_list("blocklist", field_value, values) do
    normalized = normalize_value(field_value)

    if normalized in values do
      {:violation, %{list_type: "blocklist", matched_value: true}}
    else
      {:ok, :passed}
    end
  end

  # Allowlist: violation if field value is NOT in the list
  defp evaluate_list("allowlist", nil, _values) do
    # nil field for allowlist = not in the list = violation
    {:violation, %{list_type: "allowlist", matched_value: false}}
  end

  defp evaluate_list("allowlist", _field_value, []) do
    # Empty allowlist = everything blocked
    {:violation, %{list_type: "allowlist", matched_value: false}}
  end

  defp evaluate_list("allowlist", field_value, values) do
    normalized = normalize_value(field_value)

    if normalized in values do
      {:ok, :passed}
    else
      {:violation, %{list_type: "allowlist", matched_value: false}}
    end
  end

  defp evaluate_list(unknown_type, _field_value, _values) do
    Logger.warning("[ListMatch] Unknown list_type: #{inspect(unknown_type)}")
    {:ok, :passed}
  end

  # Safe field access - only allowed fields, never arbitrary struct access
  defp safe_field_atom(field) when is_binary(field) do
    atom = String.to_existing_atom(field)
    if atom in @allowed_fields, do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp safe_field_atom(field) when is_atom(field) do
    if field in @allowed_fields, do: field, else: nil
  end

  defp safe_field_atom(_), do: nil

  # Extract field value from event struct/map
  defp extract_field_value(event, :agent_name) do
    if is_map(event) and Map.has_key?(event, :registered_agent) and
         not is_nil(event.registered_agent) do
      event.registered_agent.name
    end
  end

  defp extract_field_value(event, :source_ip), do: Map.get(event, :source_ip)
  defp extract_field_value(event, :content), do: Map.get(event, :content)

  defp extract_field_value(event, :event_type) do
    case Map.get(event, :event_type) do
      nil -> nil
      type -> to_string(type)
    end
  end

  defp extract_field_value(_event, nil) do
    Logger.warning("[ListMatch] Invalid or disallowed field in rule config")
    nil
  end

  defp normalize_value(nil), do: nil

  defp normalize_value(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end

  defp normalize_value(value), do: to_string(value) |> normalize_value()
end
