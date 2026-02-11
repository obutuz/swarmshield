defmodule Swarmshield.Repo.Migrations.CreateRegisteredAgents do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:registered_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :api_key_hash, :string, null: false
      add :api_key_prefix, :string, null: false, size: 8
      add :agent_type, :string, null: false, default: "autonomous"
      add :status, :string, null: false, default: "active"
      add :risk_level, :string, null: false, default: "medium"
      add :metadata, :map, default: %{}
      add :last_seen_at, :utc_datetime
      add :event_count, :integer, null: false, default: 0

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:registered_agents, [:api_key_hash])
    create_if_not_exists index(:registered_agents, [:workspace_id, :status])
    create_if_not_exists index(:registered_agents, [:agent_type])
    create_if_not_exists unique_index(:registered_agents, [:workspace_id, :name])
  end
end
