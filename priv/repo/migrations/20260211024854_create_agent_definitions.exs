defmodule Swarmshield.Repo.Migrations.CreateAgentDefinitions do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:agent_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :role, :string, null: false
      add :expertise, {:array, :string}, default: []
      add :system_prompt, :text, null: false
      add :model, :string, null: false, default: "claude-opus-4-6"
      add :temperature, :float, default: 0.3
      add :max_tokens, :integer, default: 4096
      add :enabled, :boolean, default: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:agent_definitions, [:workspace_id, :enabled])
    create_if_not_exists index(:agent_definitions, [:workspace_id, :role])
  end
end
