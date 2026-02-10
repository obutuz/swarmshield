defmodule Swarmshield.Repo.Migrations.CreateRoles do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :is_system, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:roles, [:name])
  end
end
