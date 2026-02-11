defmodule Swarmshield.Repo.Migrations.AddMissingIndexes do
  @moduledoc """
  Adds missing foreign key indexes and performance indexes identified by
  comprehensive audit. PostgreSQL does NOT auto-create indexes on FK columns.

  P0 (Critical FK indexes - prevent full table scans on JOIN/DELETE):
    - policy_violations.resolved_by_id
    - workflow_steps.prompt_template_id
    - analysis_sessions.consensus_policy_id

  P1 (High priority - dashboard filtering at 20M+ scale):
    - audit_entries.resource_id
    - agent_events.severity
    - policy_violations.severity

  P2 (Performance optimization):
    - registered_agents.last_seen_at
    - analysis_sessions.completed_at

  All indexes use create_if_not_exists for idempotency.
  """
  use Ecto.Migration

  @disable_ddl_transaction false

  def change do
    # P0: Critical FK indexes
    create_if_not_exists index(:policy_violations, [:resolved_by_id])
    create_if_not_exists index(:workflow_steps, [:prompt_template_id])
    create_if_not_exists index(:analysis_sessions, [:consensus_policy_id])

    # P1: Dashboard and filtering indexes
    create_if_not_exists index(:audit_entries, [:resource_id])
    create_if_not_exists index(:agent_events, [:severity])
    create_if_not_exists index(:policy_violations, [:severity])

    # P2: Time-based query optimization
    create_if_not_exists index(:registered_agents, [:last_seen_at])
    create_if_not_exists index(:analysis_sessions, [:completed_at])
  end
end
