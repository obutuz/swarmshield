defmodule Swarmshield.Repo.Migrations.CreateConsensusPolicies do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:consensus_policies, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :strategy, :string, null: false
      add :threshold, :float
      add :weights, :map, default: %{}
      add :require_unanimous_on, {:array, :string}, default: []
      add :enabled, :boolean, default: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:consensus_policies, [:workspace_id, :enabled])
  end
end
