defmodule Swarmshield.Repo.Migrations.CreatePromptTemplates do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:prompt_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :template, :text, null: false
      add :variables, {:array, :string}, default: []
      add :category, :string
      add :version, :integer, default: 1
      add :enabled, :boolean, default: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:prompt_templates, [:workspace_id, :category])
    create_if_not_exists index(:prompt_templates, [:workspace_id, :enabled])
  end
end
