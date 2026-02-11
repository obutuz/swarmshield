defmodule Swarmshield.Repo.Migrations.AddUniqueNameIndexesForPolicyAndDetectionRules do
  use Ecto.Migration

  def change do
    # Rule names must be unique within a workspace for seed idempotency
    create_if_not_exists unique_index(:policy_rules, [:workspace_id, :name])
    create_if_not_exists unique_index(:detection_rules, [:workspace_id, :name])
  end
end
