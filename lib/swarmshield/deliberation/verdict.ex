defmodule Swarmshield.Deliberation.Verdict do
  @moduledoc """
  Verdict is the final consensus decision from a deliberation session.

  Captures the collective vote, reasoning, and recommended action.
  One verdict per analysis session. Verdicts are immutable after creation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @decisions [:allow, :flag, :block, :escalate]

  schema "verdicts" do
    field :decision, Ecto.Enum, values: @decisions
    field :confidence, :float
    field :reasoning, :string
    field :dissenting_opinions, {:array, :map}, default: []
    field :vote_breakdown, :map, default: %{}
    field :recommended_actions, {:array, :string}, default: []
    field :consensus_reached, :boolean, default: false
    field :consensus_strategy_used, :string

    belongs_to :analysis_session, Swarmshield.Deliberation.AnalysisSession

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating verdicts. Verdicts are immutable - no update changeset.
  """
  def create_changeset(verdict, attrs) do
    verdict
    |> cast(attrs, [
      :decision,
      :confidence,
      :reasoning,
      :dissenting_opinions,
      :vote_breakdown,
      :recommended_actions,
      :consensus_reached,
      :consensus_strategy_used
    ])
    |> validate_required([:decision, :confidence, :reasoning])
    |> validate_number(:confidence,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> unique_constraint(:analysis_session_id,
      message: "a verdict already exists for this analysis session"
    )
    |> foreign_key_constraint(:analysis_session_id)
  end
end
