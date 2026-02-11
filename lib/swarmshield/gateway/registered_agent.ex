defmodule Swarmshield.Gateway.RegisteredAgent do
  @moduledoc """
  RegisteredAgent represents an external AI agent monitored by SwarmShield.

  Each agent has an API key for authentication and metadata about its
  capabilities and risk profile. Agents are always scoped to a workspace.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @agent_types [:autonomous, :semi_autonomous, :tool_agent, :chatbot]
  @statuses [:active, :suspended, :revoked]
  @risk_levels [:low, :medium, :high, :critical]

  schema "registered_agents" do
    field :name, :string
    field :description, :string
    field :api_key_hash, :string, redact: true
    field :api_key_prefix, :string
    field :agent_type, Ecto.Enum, values: @agent_types, default: :autonomous
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :risk_level, Ecto.Enum, values: @risk_levels, default: :medium
    field :metadata, :map, default: %{}
    field :last_seen_at, :utc_datetime
    field :event_count, :integer, default: 0

    belongs_to :workspace, Swarmshield.Accounts.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc """
  User-facing changeset for creating/updating registered agents.
  Never includes sensitive fields like api_key_hash, api_key_prefix,
  event_count, or last_seen_at.
  """
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :description, :agent_type, :status, :risk_level, :metadata])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_status_transition()
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :name],
      message: "an agent with this name already exists in this workspace"
    )
  end

  @doc """
  Internal changeset for setting API key credentials.
  Only used by system code during agent registration.
  """
  def api_key_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:api_key_hash, :api_key_prefix])
    |> validate_required([:api_key_hash, :api_key_prefix])
    |> validate_length(:api_key_prefix, is: 8)
    |> unique_constraint(:api_key_hash)
  end

  @doc """
  Internal changeset for setting workspace_id. Only used by system code.
  """
  def workspace_changeset(agent, workspace_id) when is_binary(workspace_id) do
    agent
    |> change(%{workspace_id: workspace_id})
    |> validate_required([:workspace_id])
    |> foreign_key_constraint(:workspace_id)
  end

  @doc """
  Internal changeset for updating event_count and last_seen_at.
  Used by the gateway on event ingestion.
  """
  def activity_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:event_count, :last_seen_at])
  end

  @doc """
  Generates a cryptographically secure API key.

  Returns `{raw_key, hash, prefix}` where:
  - `raw_key` is the base64-encoded key shown once to the user
  - `hash` is the SHA256 hash stored in the database
  - `prefix` is the first 8 characters for display identification
  """
  def generate_api_key do
    raw_bytes = :crypto.strong_rand_bytes(32)
    raw_key = Base.url_encode64(raw_bytes, padding: false)
    hash = :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
    prefix = String.slice(raw_key, 0, 8)

    {raw_key, hash, prefix}
  end

  # Validates that suspended agents cannot go directly to active.
  # Revoked agents cannot be reactivated at all.
  defp validate_status_transition(changeset) do
    case {changeset.data.status, get_change(changeset, :status)} do
      {_current, nil} ->
        changeset

      {:revoked, new_status} when new_status != :revoked ->
        add_error(changeset, :status, "revoked agents cannot be reactivated")

      {:suspended, :active} ->
        add_error(
          changeset,
          :status,
          "suspended agents must go through review before reactivation"
        )

      _valid_transition ->
        changeset
    end
  end
end
