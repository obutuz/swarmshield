defmodule Swarmshield.Repo.Migrations.CreatePolicyViolations do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:policy_violations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :action_taken, :string, null: false
      add :severity, :string, null: false, default: "medium"
      add :details, :map, default: %{}
      add :resolved, :boolean, default: false
      add :resolved_at, :utc_datetime
      add :resolution_notes, :string

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_event_id, references(:agent_events, type: :binary_id, on_delete: :delete_all),
        null: false

      add :policy_rule_id, references(:policy_rules, type: :binary_id, on_delete: :delete_all),
        null: false

      add :resolved_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:policy_violations, [:workspace_id, :inserted_at])
    create_if_not_exists index(:policy_violations, [:agent_event_id])
    create_if_not_exists index(:policy_violations, [:policy_rule_id])
    create_if_not_exists index(:policy_violations, [:workspace_id, :resolved])
  end
end
