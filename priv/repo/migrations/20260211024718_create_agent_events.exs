defmodule Swarmshield.Repo.Migrations.CreateAgentEvents do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:agent_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_type, :string, null: false
      add :content, :text, null: false
      add :payload, :map, default: %{}
      add :source_ip, :string
      add :severity, :string, null: false, default: "info"
      add :status, :string, null: false, default: "pending"
      add :evaluation_result, :map, default: %{}
      add :evaluated_at, :utc_datetime
      add :flagged_reason, :string

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :registered_agent_id,
          references(:registered_agents, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:agent_events, [:workspace_id, :inserted_at])
    create_if_not_exists index(:agent_events, [:registered_agent_id, :inserted_at])
    create_if_not_exists index(:agent_events, [:status])
    create_if_not_exists index(:agent_events, [:event_type])
    create_if_not_exists index(:agent_events, [:workspace_id, :status])
  end
end
