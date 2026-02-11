defmodule Swarmshield.Policies.PolicyViolation do
  @moduledoc """
  PolicyViolation records when an agent event matches a policy rule.

  Links the event to the rule that triggered and captures the evaluation
  details. Violations can be resolved by authorized users.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @actions_taken [:flagged, :blocked]
  @severities [:low, :medium, :high, :critical]

  schema "policy_violations" do
    field :action_taken, Ecto.Enum, values: @actions_taken
    field :severity, Ecto.Enum, values: @severities, default: :medium
    field :details, :map, default: %{}
    field :resolved, :boolean, default: false
    field :resolved_by_id, :binary_id
    field :resolved_at, :utc_datetime
    field :resolution_notes, :string

    belongs_to :workspace, Swarmshield.Accounts.Workspace
    belongs_to :agent_event, Swarmshield.Gateway.AgentEvent
    belongs_to :policy_rule, Swarmshield.Policies.PolicyRule

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating policy violations. Created by PolicyEngine.
  """
  def changeset(violation, attrs) do
    violation
    |> cast(attrs, [:action_taken, :severity, :details])
    |> validate_required([:action_taken, :severity])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:agent_event_id)
    |> foreign_key_constraint(:policy_rule_id)
  end

  @doc """
  Changeset for resolving a violation.
  """
  def resolution_changeset(violation, attrs) do
    violation
    |> cast(attrs, [:resolved, :resolved_by_id, :resolved_at, :resolution_notes])
    |> validate_required([:resolved, :resolved_by_id, :resolved_at])
    |> validate_length(:resolution_notes, max: 5000)
  end
end
