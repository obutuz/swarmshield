defmodule Swarmshield.Repo.Migrations.CreateDeliberationMessages do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:deliberation_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :message_type, :string, null: false
      add :content, :text, null: false
      add :round, :integer, default: 1
      add :in_reply_to_id, :binary_id
      add :tokens_used, :integer, default: 0
      add :metadata, :map, default: %{}

      add :analysis_session_id,
          references(:analysis_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :agent_instance_id,
          references(:agent_instances, type: :binary_id, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:deliberation_messages, [:analysis_session_id, :round])
    create_if_not_exists index(:deliberation_messages, [:agent_instance_id])
    create_if_not_exists index(:deliberation_messages, [:analysis_session_id, :message_type])
  end
end
