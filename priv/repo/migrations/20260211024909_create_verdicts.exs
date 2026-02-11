defmodule Swarmshield.Repo.Migrations.CreateVerdicts do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:verdicts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :decision, :string, null: false
      add :confidence, :float, null: false
      add :reasoning, :text, null: false
      add :dissenting_opinions, {:array, :map}, default: []
      add :vote_breakdown, :map, default: %{}
      add :recommended_actions, {:array, :string}, default: []
      add :consensus_reached, :boolean, default: false
      add :consensus_strategy_used, :string

      add :analysis_session_id,
          references(:analysis_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:verdicts, [:analysis_session_id])
  end
end
