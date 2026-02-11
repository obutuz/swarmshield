defmodule Swarmshield.Repo.Migrations.CreateWorkflowSteps do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:workflow_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :position, :integer, null: false
      add :name, :string, null: false
      add :execution_mode, :string, default: "sequential"
      add :timeout_seconds, :integer, default: 120
      add :retry_count, :integer, default: 1
      add :config, :map, default: %{}

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :agent_definition_id,
          references(:agent_definitions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :prompt_template_id,
          references(:prompt_templates, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:workflow_steps, [:workflow_id, :position])
    create_if_not_exists index(:workflow_steps, [:agent_definition_id])
  end
end
