defmodule Swarmshield.Policies.Rules.PayloadSize do
  @moduledoc """
  Implements payload size checking for agent events.

  Validates that event content and payload don't exceed configured size limits.
  All size limits come from database rule config - zero hardcoded byte limits.

  Security:
  - Jason.encode! wrapped in try/rescue to prevent crash on non-serializable data
  """

  require Logger

  @doc """
  Evaluates an event's content and payload against size limits.

  Rule config format:
  ```
  %{
    "max_content_bytes" => integer | nil,
    "max_payload_bytes" => integer | nil
  }
  ```

  At least one limit must be set. Returns `{:ok, :within_limit}` or
  `{:violation, %{content_bytes: N, payload_bytes: N, limits: %{...}}}`.
  """
  def evaluate(event, rule) do
    config = rule.config

    max_content = get_config_int(config, "max_content_bytes")
    max_payload = get_config_int(config, "max_payload_bytes")

    content_bytes = content_byte_size(event.content)
    payload_bytes = payload_byte_size(event.payload)

    content_exceeded = exceeded?(content_bytes, max_content)
    payload_exceeded = exceeded?(payload_bytes, max_payload)

    if content_exceeded or payload_exceeded do
      {:violation,
       %{
         content_bytes: content_bytes,
         payload_bytes: payload_bytes,
         limits: %{
           max_content_bytes: max_content,
           max_payload_bytes: max_payload
         }
       }}
    else
      {:ok, :within_limit}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp content_byte_size(nil), do: 0
  defp content_byte_size(content) when is_binary(content), do: byte_size(content)
  defp content_byte_size(_), do: 0

  defp payload_byte_size(nil), do: 0

  defp payload_byte_size(payload) when is_map(payload) do
    payload |> Jason.encode!() |> byte_size()
  rescue
    _ ->
      Logger.warning("[PayloadSize] Failed to encode payload for size check")
      0
  end

  defp payload_byte_size(_), do: 0

  # Only check if limit is configured (not nil)
  defp exceeded?(_actual, nil), do: false
  defp exceeded?(actual, limit) when is_integer(limit) and limit > 0, do: actual > limit
  defp exceeded?(_actual, _limit), do: false

  defp get_config_int(config, key) do
    value = config[key] || config[String.to_existing_atom(key)]

    case value do
      v when is_integer(v) and v > 0 -> v
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end
end
