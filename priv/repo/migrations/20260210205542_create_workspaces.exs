defmodule Swarmshield.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :string
      add :api_key_hash, :string
      add :api_key_prefix, :string
      add :status, :string, null: false, default: "active"
      add :settings, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:workspaces, [:slug])
    create_if_not_exists index(:workspaces, [:status])
    create_if_not_exists index(:workspaces, [:api_key_hash])
  end
end
