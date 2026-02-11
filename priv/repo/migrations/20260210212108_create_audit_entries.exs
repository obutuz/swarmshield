defmodule Swarmshield.Repo.Migrations.CreateAuditEntries do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:audit_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :binary_id
      add :actor_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :actor_email, :string
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :nilify_all)
      add :metadata, :map, default: %{}
      add :ip_address, :string
      add :user_agent, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create_if_not_exists index(:audit_entries, [:workspace_id])
    create_if_not_exists index(:audit_entries, [:actor_id])
    create_if_not_exists index(:audit_entries, [:action])
    create_if_not_exists index(:audit_entries, [:resource_type])
    create_if_not_exists index(:audit_entries, [:inserted_at])
    create_if_not_exists index(:audit_entries, [:workspace_id, :inserted_at])
  end
end
