defmodule Swarmshield.Gateway.AgentEvent do
  @moduledoc """
  AgentEvent captures a single action or output from a monitored AI agent.

  This is the primary data ingested through the API gateway. Events are
  evaluated against policy rules and may trigger deliberation sessions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @event_types [:action, :output, :tool_call, :message, :error]
  @severities [:info, :warning, :error, :critical]
  @statuses [:allowed, :flagged, :blocked, :pending]

  @max_content_bytes 1_048_576
  @max_payload_bytes 1_048_576

  schema "agent_events" do
    field :event_type, Ecto.Enum, values: @event_types
    field :content, :string
    field :payload, :map, default: %{}
    field :source_ip, :string
    field :severity, Ecto.Enum, values: @severities, default: :info
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :evaluation_result, :map, default: %{}
    field :evaluated_at, :utc_datetime
    field :flagged_reason, :string

    belongs_to :workspace, Swarmshield.Accounts.Workspace
    belongs_to :registered_agent, Swarmshield.Gateway.RegisteredAgent

    timestamps(type: :utc_datetime)
  end

  @doc """
  External-facing changeset for API event ingestion.
  Only casts fields that external agents are allowed to set.
  Status, evaluation_result, evaluated_at, flagged_reason, and source_ip
  are set server-side by the PolicyEngine and connection.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :content, :payload, :severity])
    |> validate_required([:event_type, :content])
    |> validate_length(:content, max: @max_content_bytes, count: :bytes)
    |> validate_payload_size()
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:registered_agent_id)
  end

  @doc """
  Internal changeset for PolicyEngine to set evaluation results.
  """
  def evaluation_changeset(event, attrs) do
    event
    |> cast(attrs, [:status, :evaluation_result, :evaluated_at, :flagged_reason])
    |> validate_required([:status])
  end

  @doc """
  Internal changeset for setting source_ip from connection.
  """
  def source_changeset(event, attrs) do
    event
    |> cast(attrs, [:source_ip])
  end

  defp validate_payload_size(changeset) do
    case get_change(changeset, :payload) do
      nil ->
        changeset

      payload when is_map(payload) ->
        encoded = Jason.encode!(payload)

        if byte_size(encoded) > @max_payload_bytes do
          add_error(
            changeset,
            :payload,
            "payload exceeds maximum size of #{@max_payload_bytes} bytes"
          )
        else
          changeset
        end

      _other ->
        changeset
    end
  end
end
