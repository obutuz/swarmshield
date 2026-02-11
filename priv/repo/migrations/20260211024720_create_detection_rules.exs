defmodule Swarmshield.Repo.Migrations.CreateDetectionRules do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:detection_rules, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :detection_type, :string, null: false
      add :pattern, :string
      add :keywords, {:array, :string}, default: []
      add :severity, :string, null: false, default: "medium"
      add :enabled, :boolean, null: false, default: true
      add :category, :string

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:detection_rules, [:workspace_id, :enabled])
    create_if_not_exists index(:detection_rules, [:workspace_id, :detection_type])
    create_if_not_exists index(:detection_rules, [:workspace_id, :category])
  end
end
