defmodule Swarmshield.Deliberation.ConsensusPolicy do
  @moduledoc """
  ConsensusPolicy defines the voting strategy for reaching a verdict
  after deliberation.

  Supports majority, supermajority, unanimous, and weighted voting
  strategies. All parameters are database-driven.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @strategies [:majority, :supermajority, :unanimous, :weighted]

  schema "consensus_policies" do
    field :name, :string
    field :description, :string
    field :strategy, Ecto.Enum, values: @strategies
    field :threshold, :float
    field :weights, :map, default: %{}
    field :require_unanimous_on, {:array, :string}, default: []
    field :enabled, :boolean, default: true

    belongs_to :workspace, Swarmshield.Accounts.Workspace

    timestamps(type: :utc_datetime)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :name,
      :description,
      :strategy,
      :threshold,
      :weights,
      :require_unanimous_on,
      :enabled
    ])
    |> validate_required([:name, :strategy])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_number(:threshold,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_weights_positive()
    |> foreign_key_constraint(:workspace_id)
  end

  defp validate_weights_positive(changeset) do
    case get_field(changeset, :weights) do
      nil ->
        changeset

      weights when is_map(weights) ->
        all_positive? = Enum.all?(Map.values(weights), fn v -> is_number(v) and v > 0 end)

        if all_positive?,
          do: changeset,
          else: add_error(changeset, :weights, "all weight values must be positive numbers")

      _other ->
        changeset
    end
  end
end
