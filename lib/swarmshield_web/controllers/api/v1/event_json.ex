defmodule SwarmshieldWeb.Api.V1.EventJSON do
  @moduledoc """
  JSON rendering for AgentEvent API responses.
  Never exposes internal fields: workspace_id, api_key_hash, api_key_prefix.
  """

  alias Swarmshield.Gateway.AgentEvent

  def index(%{events: events, total_count: total_count}) do
    %{data: Enum.map(events, &event_data/1), total_count: total_count}
  end

  def show(%{event: event}) do
    %{data: event_data(event)}
  end

  defp event_data(%AgentEvent{} = event) do
    %{
      id: event.id,
      event_type: event.event_type,
      content: event.content,
      payload: event.payload,
      source_ip: event.source_ip,
      severity: event.severity,
      status: event.status,
      evaluation_result: event.evaluation_result,
      evaluated_at: event.evaluated_at,
      flagged_reason: event.flagged_reason,
      registered_agent_id: event.registered_agent_id,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end
end
