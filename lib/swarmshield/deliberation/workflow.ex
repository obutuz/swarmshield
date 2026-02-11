defmodule Swarmshield.Deliberation.Workflow do
  @moduledoc """
  Workflow defines an analysis pipeline - an ordered sequence of steps
  that process a flagged event through multiple AI agents.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @trigger_types [:flagged, :blocked, :manual, :all]

  schema "workflows" do
    field :name, :string
    field :description, :string
    field :trigger_on, Ecto.Enum, values: @trigger_types, default: :flagged
    field :enabled, :boolean, default: true
    field :timeout_seconds, :integer, default: 300
    field :max_retries, :integer, default: 2

    belongs_to :workspace, Swarmshield.Accounts.Workspace

    has_many :workflow_steps, Swarmshield.Deliberation.WorkflowStep,
      preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [:name, :description, :trigger_on, :enabled, :timeout_seconds, :max_retries])
    |> validate_required([:name, :trigger_on])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_number(:timeout_seconds,
      greater_than_or_equal_to: 30,
      less_than_or_equal_to: 3600
    )
    |> validate_number(:max_retries,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 10
    )
    |> foreign_key_constraint(:workspace_id)
  end
end
