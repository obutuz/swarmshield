defmodule Swarmshield.Repo.Migrations.CreateUserWorkspaceRoles do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:user_workspace_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :role_id, references(:roles, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:user_workspace_roles, [:user_id, :workspace_id])
    create_if_not_exists index(:user_workspace_roles, [:workspace_id])
    create_if_not_exists index(:user_workspace_roles, [:role_id])
  end
end
