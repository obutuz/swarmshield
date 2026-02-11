defmodule Swarmshield.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :trigger_on, :string, null: false, default: "flagged"
      add :enabled, :boolean, default: true
      add :timeout_seconds, :integer, default: 300
      add :max_retries, :integer, default: 2

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:workflows, [:workspace_id, :enabled])
    create_if_not_exists index(:workflows, [:workspace_id, :trigger_on])
  end
end
