defmodule Swarmshield.Repo.Migrations.CreateAgentInstances do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:agent_instances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false, default: "pending"
      add :role, :string
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :initial_assessment, :text
      add :vote, :string
      add :confidence, :float
      add :tokens_used, :integer, default: 0
      add :cost_cents, :integer, default: 0
      add :error_message, :string

      add :analysis_session_id,
          references(:analysis_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :agent_definition_id,
          references(:agent_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:agent_instances, [:analysis_session_id, :status])
    create_if_not_exists index(:agent_instances, [:agent_definition_id])
  end
end
