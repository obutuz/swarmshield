defmodule Swarmshield.Deliberation.AgentDefinition do
  @moduledoc """
  AgentDefinition describes an internal Opus 4.6 analyzer persona used
  in deliberation.

  Each definition specifies the agent's role, expertise, and system prompt
  for the LLM. All configuration is database-driven.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_system_prompt_bytes 102_400

  @approved_models [
    "claude-opus-4-6",
    "claude-sonnet-4-5-20250929",
    "claude-haiku-4-5-20251001"
  ]

  schema "agent_definitions" do
    field :name, :string
    field :description, :string
    field :role, :string
    field :expertise, {:array, :string}, default: []
    field :system_prompt, :string
    field :model, :string, default: "claude-opus-4-6"
    field :temperature, :float, default: 0.3
    field :max_tokens, :integer, default: 4096
    field :enabled, :boolean, default: true

    belongs_to :workspace, Swarmshield.Accounts.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc """
  User-facing changeset for creating/updating agent definitions.
  """
  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [
      :name,
      :description,
      :role,
      :expertise,
      :system_prompt,
      :model,
      :temperature,
      :max_tokens,
      :enabled
    ])
    |> validate_required([:name, :role, :system_prompt])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_length(:role, min: 1, max: 255)
    |> validate_length(:system_prompt, max: @max_system_prompt_bytes, count: :bytes)
    |> validate_number(:temperature,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:max_tokens,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 32_768
    )
    |> validate_inclusion(:model, @approved_models)
    |> foreign_key_constraint(:workspace_id)
  end

  def approved_models, do: @approved_models
end
