defmodule Swarmshield.Repo.Migrations.CreateGhostProtocolConfigs do
  use Ecto.Migration

  def change do
    # -------------------------------------------------------------------
    # Ghost Protocol Config table
    # -------------------------------------------------------------------
    create_if_not_exists table(:ghost_protocol_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :wipe_strategy, :string, null: false
      add :wipe_delay_seconds, :integer, default: 0, null: false
      add :wipe_fields, {:array, :string}, default: [], null: false
      add :retain_verdict, :boolean, default: true, null: false
      add :retain_audit, :boolean, default: true, null: false
      add :max_session_duration_seconds, :integer, null: false
      add :auto_terminate_on_expiry, :boolean, default: true, null: false
      add :crypto_shred, :boolean, default: false, null: false
      add :enabled, :boolean, default: true, null: false
      add :metadata, :map, default: %{}, null: false

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:ghost_protocol_configs, [:workspace_id, :slug])
    create_if_not_exists index(:ghost_protocol_configs, [:workspace_id, :enabled])

    # -------------------------------------------------------------------
    # Add ghost_protocol_config_id FK to workflows
    # -------------------------------------------------------------------
    alter table(:workflows) do
      add_if_not_exists :ghost_protocol_config_id,
                        references(:ghost_protocol_configs,
                          type: :binary_id,
                          on_delete: :nilify_all
                        )
    end

    create_if_not_exists index(:workflows, [:ghost_protocol_config_id])

    # -------------------------------------------------------------------
    # Add GhostProtocol lifecycle fields to analysis_sessions
    # -------------------------------------------------------------------
    alter table(:analysis_sessions) do
      add_if_not_exists :input_content_hash, :string
      add_if_not_exists :expires_at, :utc_datetime
    end

    create_if_not_exists index(:analysis_sessions, [:expires_at],
                           where: "expires_at IS NOT NULL",
                           name: :analysis_sessions_expires_at_partial_idx
                         )

    # -------------------------------------------------------------------
    # Add terminated_at to agent_instances for GhostProtocol kill tracking
    # -------------------------------------------------------------------
    alter table(:agent_instances) do
      add_if_not_exists :terminated_at, :utc_datetime
    end
  end
end
