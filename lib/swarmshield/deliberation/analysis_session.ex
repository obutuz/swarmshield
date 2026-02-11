defmodule Swarmshield.Deliberation.AnalysisSession do
  @moduledoc """
  AnalysisSession represents a single deliberation instance.

  Multiple AI agents analyze a flagged event and debate to reach a verdict.
  Tracks the session lifecycle from pending through analysis, deliberation,
  to verdict.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:pending, :analyzing, :deliberating, :voting, :completed, :failed, :timed_out]
  @triggers [:automatic, :manual]

  schema "analysis_sessions" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :trigger, Ecto.Enum, values: @triggers
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :error_message, :string
    field :metadata, :map, default: %{}
    field :total_tokens_used, :integer, default: 0
    field :total_cost_cents, :integer, default: 0

    belongs_to :workspace, Swarmshield.Accounts.Workspace
    belongs_to :workflow, Swarmshield.Deliberation.Workflow
    belongs_to :consensus_policy, Swarmshield.Deliberation.ConsensusPolicy
    belongs_to :agent_event, Swarmshield.Gateway.AgentEvent

    has_many :agent_instances, Swarmshield.Deliberation.AgentInstance
    has_many :deliberation_messages, Swarmshield.Deliberation.DeliberationMessage
    has_one :verdict, Swarmshield.Deliberation.Verdict

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:status, :trigger, :started_at, :completed_at, :error_message, :metadata])
    |> validate_required([:status, :trigger])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:consensus_policy_id)
    |> foreign_key_constraint(:agent_event_id)
  end

  @doc """
  Internal changeset for updating session status and metrics.
  """
  def status_changeset(session, attrs) do
    session
    |> cast(attrs, [
      :status,
      :started_at,
      :completed_at,
      :error_message,
      :total_tokens_used,
      :total_cost_cents
    ])
    |> validate_required([:status])
  end
end
