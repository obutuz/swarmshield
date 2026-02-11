defmodule Swarmshield.PoliciesFixtures do
  @moduledoc """
  Test helpers for creating entities in the `Swarmshield.Policies` context.
  """

  alias Swarmshield.Policies.DetectionRule
  alias Swarmshield.Policies.PolicyRule
  alias Swarmshield.Policies.PolicyViolation
  alias Swarmshield.Repo

  import Swarmshield.AccountsFixtures, only: [workspace_fixture: 0]
  import Swarmshield.GatewayFixtures, only: [agent_event_fixture: 1]

  # PolicyRule fixtures

  def unique_policy_rule_name, do: "rule-#{System.unique_integer([:positive])}"

  def valid_policy_rule_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_policy_rule_name(),
      description: "A test policy rule",
      rule_type: :rate_limit,
      action: :flag,
      priority: 10,
      enabled: true,
      config: %{"max_events" => 100, "window_seconds" => 60}
    })
  end

  @doc """
  Creates a policy rule with a workspace.

  Pass `workspace_id` to use an existing workspace,
  or one will be created automatically.
  """
  def policy_rule_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    rule_attrs = valid_policy_rule_attributes(attrs)

    {:ok, rule} =
      %PolicyRule{workspace_id: workspace_id}
      |> PolicyRule.changeset(rule_attrs)
      |> Repo.insert()

    rule
  end

  # DetectionRule fixtures

  def unique_detection_rule_name, do: "detection-#{System.unique_integer([:positive])}"

  def valid_detection_rule_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: unique_detection_rule_name(),
      description: "A test detection rule",
      detection_type: :regex,
      pattern: "\\b(password|secret)\\b",
      severity: :medium,
      enabled: true,
      category: "pii"
    })
  end

  @doc """
  Creates a detection rule with a workspace.
  """
  def detection_rule_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    rule_attrs = valid_detection_rule_attributes(attrs)

    {:ok, rule} =
      %DetectionRule{workspace_id: workspace_id}
      |> DetectionRule.changeset(rule_attrs)
      |> Repo.insert()

    rule
  end

  # PolicyViolation fixtures

  def valid_policy_violation_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      action_taken: :flagged,
      severity: :medium,
      details: %{"matched_pattern" => "password", "context" => "test"}
    })
  end

  @doc """
  Creates a policy violation with workspace, agent event, and policy rule.
  """
  def policy_violation_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    {agent_event_id, attrs} =
      case Map.pop(attrs, :agent_event_id) do
        {nil, rest} ->
          event = agent_event_fixture(%{workspace_id: workspace_id})
          {event.id, rest}

        {eid, rest} ->
          {eid, rest}
      end

    {policy_rule_id, attrs} =
      case Map.pop(attrs, :policy_rule_id) do
        {nil, rest} ->
          rule = policy_rule_fixture(%{workspace_id: workspace_id})
          {rule.id, rest}

        {rid, rest} ->
          {rid, rest}
      end

    violation_attrs = valid_policy_violation_attributes(attrs)

    {:ok, violation} =
      %PolicyViolation{
        workspace_id: workspace_id,
        agent_event_id: agent_event_id,
        policy_rule_id: policy_rule_id
      }
      |> PolicyViolation.changeset(violation_attrs)
      |> Repo.insert()

    violation
  end
end
