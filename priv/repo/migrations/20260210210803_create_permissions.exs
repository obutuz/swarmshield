defmodule Swarmshield.Repo.Migrations.CreatePermissions do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:permissions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :resource, :string, null: false
      add :action, :string, null: false
      add :description, :string

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:permissions, [:resource, :action])
  end
end
