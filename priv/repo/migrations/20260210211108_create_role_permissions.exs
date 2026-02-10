defmodule Swarmshield.Repo.Migrations.CreateRolePermissions do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:role_permissions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :role_id, references(:roles, type: :binary_id, on_delete: :delete_all), null: false

      add :permission_id, references(:permissions, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:role_permissions, [:role_id, :permission_id])
    create_if_not_exists index(:role_permissions, [:permission_id])
  end
end
