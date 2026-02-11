defmodule Swarmshield.Repo.Migrations.CreatePolicyRules do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:policy_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :rule_type, :string, null: false
      add :action, :string, null: false
      add :priority, :integer, null: false, default: 0
      add :enabled, :boolean, null: false, default: true
      add :config, :map, null: false
      add :applies_to_agent_types, {:array, :string}, default: []
      add :applies_to_event_types, {:array, :string}, default: []

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:policy_rules, [:workspace_id, :enabled])
    create_if_not_exists index(:policy_rules, [:workspace_id, :rule_type])
    create_if_not_exists index(:policy_rules, [:workspace_id, :priority])
  end
end
