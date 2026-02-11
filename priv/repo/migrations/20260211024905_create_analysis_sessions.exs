defmodule Swarmshield.Repo.Migrations.CreateAnalysisSessions do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:analysis_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :status, :string, null: false, default: "pending"
      add :trigger, :string, null: false
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :error_message, :string
      add :metadata, :map, default: %{}
      add :total_tokens_used, :integer, default: 0
      add :total_cost_cents, :integer, default: 0

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :consensus_policy_id,
          references(:consensus_policies, type: :binary_id, on_delete: :delete_all),
          null: false

      add :agent_event_id, references(:agent_events, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:analysis_sessions, [:workspace_id, :status])
    create_if_not_exists index(:analysis_sessions, [:workspace_id, :inserted_at])
    create_if_not_exists index(:analysis_sessions, [:agent_event_id])
    create_if_not_exists index(:analysis_sessions, [:workflow_id])
  end
end
