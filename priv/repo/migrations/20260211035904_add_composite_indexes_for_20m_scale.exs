defmodule Swarmshield.Repo.Migrations.AddCompositeIndexesFor20mScale do
  use Ecto.Migration

  def change do
    # P0: PolicyRules - optimize ETS cache loading (runs on every rule change PubSub)
    # Query: WHERE workspace_id = ? AND enabled = true ORDER BY priority DESC
    create_if_not_exists index(:policy_rules, [:workspace_id, :enabled, :priority])

    # P1: AgentEvents - optimize event_type filtered time-series queries
    # Query: WHERE workspace_id = ? AND event_type = ? ORDER BY inserted_at DESC
    create_if_not_exists index(:agent_events, [:workspace_id, :event_type, :inserted_at])

    # P1: AgentEvents - optimize severity filtered dashboard queries
    # Query: WHERE workspace_id = ? AND severity = ? ORDER BY inserted_at DESC
    create_if_not_exists index(:agent_events, [:workspace_id, :severity, :inserted_at])

    # P1: PolicyViolations - optimize severity filtered dashboards
    # Query: WHERE workspace_id = ? AND severity = ? ORDER BY inserted_at DESC
    create_if_not_exists index(:policy_violations, [:workspace_id, :severity, :inserted_at])

    # P2: PolicyViolations - optimize action_taken filtered reports
    # Query: WHERE workspace_id = ? AND action_taken = ? ORDER BY inserted_at DESC
    create_if_not_exists index(:policy_violations, [:workspace_id, :action_taken, :inserted_at])
  end
end
