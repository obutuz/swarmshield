defmodule Swarmshield.Deliberation.AgentInstance do
  @moduledoc """
  AgentInstance represents a specific AI agent participating in an
  analysis session.

  Each instance is spawned from an AgentDefinition and tracks its
  individual analysis output, vote, and resource usage.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :running, :completed, :failed, :timed_out]
  @votes [:allow, :flag, :block]

  schema "agent_instances" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :role, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :initial_assessment, :string
    field :vote, Ecto.Enum, values: @votes
    field :confidence, :float
    field :tokens_used, :integer, default: 0
    field :cost_cents, :integer, default: 0
    field :error_message, :string

    belongs_to :analysis_session, Swarmshield.Deliberation.AnalysisSession
    belongs_to :agent_definition, Swarmshield.Deliberation.AgentDefinition
    has_many :deliberation_messages, Swarmshield.Deliberation.DeliberationMessage

    timestamps(type: :utc_datetime)
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :status,
      :role,
      :started_at,
      :completed_at,
      :initial_assessment,
      :vote,
      :confidence,
      :tokens_used,
      :cost_cents,
      :error_message
    ])
    |> validate_required([:status])
    |> validate_confidence()
    |> foreign_key_constraint(:analysis_session_id)
    |> foreign_key_constraint(:agent_definition_id)
  end

  defp validate_confidence(changeset) do
    case get_change(changeset, :confidence) do
      nil ->
        changeset

      confidence when is_float(confidence) ->
        validate_number(changeset, :confidence,
          greater_than_or_equal_to: 0.0,
          less_than_or_equal_to: 1.0
        )

      _other ->
        changeset
    end
  end
end
