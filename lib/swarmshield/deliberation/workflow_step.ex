defmodule Swarmshield.Deliberation.WorkflowStep do
  @moduledoc """
  WorkflowStep is an ordered step in a workflow pipeline.

  Each step references an agent definition and optionally a prompt template.
  Steps can run in parallel or sequentially within a workflow.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @execution_modes [:sequential, :parallel]

  schema "workflow_steps" do
    field :position, :integer
    field :name, :string
    field :execution_mode, Ecto.Enum, values: @execution_modes, default: :sequential
    field :timeout_seconds, :integer, default: 120
    field :retry_count, :integer, default: 1
    field :config, :map, default: %{}

    belongs_to :workflow, Swarmshield.Deliberation.Workflow
    belongs_to :agent_definition, Swarmshield.Deliberation.AgentDefinition
    belongs_to :prompt_template, Swarmshield.Deliberation.PromptTemplate

    timestamps(type: :utc_datetime)
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :position,
      :name,
      :execution_mode,
      :timeout_seconds,
      :retry_count,
      :config,
      :workflow_id,
      :agent_definition_id,
      :prompt_template_id
    ])
    |> validate_required([:position, :name, :workflow_id, :agent_definition_id])
    |> validate_number(:position, greater_than_or_equal_to: 1)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_number(:timeout_seconds,
      greater_than_or_equal_to: 10,
      less_than_or_equal_to: 3600
    )
    |> validate_number(:retry_count,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 5
    )
    |> unique_constraint([:workflow_id, :position],
      message: "position already taken in this workflow"
    )
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:agent_definition_id)
    |> foreign_key_constraint(:prompt_template_id)
  end
end
