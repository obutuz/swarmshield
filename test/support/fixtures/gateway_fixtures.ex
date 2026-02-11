defmodule Swarmshield.GatewayFixtures do
  @moduledoc """
  Test helpers for creating entities in the `Swarmshield.Gateway` context.
  """

  alias Swarmshield.Gateway.RegisteredAgent
  alias Swarmshield.Repo

  import Swarmshield.AccountsFixtures, only: [workspace_fixture: 0]

  def unique_agent_name, do: "agent-#{System.unique_integer([:positive])}"

  def valid_registered_agent_attributes(attrs \\ %{}) do
    {_raw_key, hash, prefix} = RegisteredAgent.generate_api_key()

    Enum.into(attrs, %{
      name: unique_agent_name(),
      description: "A test agent",
      api_key_hash: hash,
      api_key_prefix: prefix,
      agent_type: :autonomous,
      status: :active,
      risk_level: :medium,
      metadata: %{}
    })
  end

  @doc """
  Creates a registered agent with a workspace.

  Pass `workspace_id` in attrs to use an existing workspace,
  or one will be created automatically.
  """
  def registered_agent_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    agent_attrs = valid_registered_agent_attributes(attrs)

    {:ok, agent} =
      %RegisteredAgent{workspace_id: workspace_id}
      |> RegisteredAgent.changeset(agent_attrs)
      |> Ecto.Changeset.change(%{
        api_key_hash: agent_attrs.api_key_hash,
        api_key_prefix: agent_attrs.api_key_prefix
      })
      |> Repo.insert()

    agent
  end

  # AgentEvent fixtures

  alias Swarmshield.Gateway.AgentEvent

  def valid_agent_event_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      event_type: :action,
      content: "Test agent event content",
      payload: %{"key" => "value"},
      severity: :info
    })
  end

  @doc """
  Creates an agent event with a registered agent and workspace.

  Pass `workspace_id` and `registered_agent_id` in attrs to use existing records,
  or they will be created automatically.
  """
  def agent_event_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    {registered_agent_id, attrs} =
      case Map.pop(attrs, :registered_agent_id) do
        {nil, rest} ->
          agent = registered_agent_fixture(%{workspace_id: workspace_id})
          {agent.id, rest}

        {aid, rest} ->
          {aid, rest}
      end

    # Extract server-side fields that aren't cast by the external changeset
    {status, attrs} = Map.pop(attrs, :status)
    {evaluation_result, attrs} = Map.pop(attrs, :evaluation_result)
    {evaluated_at, attrs} = Map.pop(attrs, :evaluated_at)
    {flagged_reason, attrs} = Map.pop(attrs, :flagged_reason)
    {source_ip, attrs} = Map.pop(attrs, :source_ip)

    event_attrs = valid_agent_event_attributes(attrs)

    server_fields =
      %{}
      |> maybe_put(:status, status)
      |> maybe_put(:evaluation_result, evaluation_result)
      |> maybe_put(:evaluated_at, evaluated_at)
      |> maybe_put(:flagged_reason, flagged_reason)
      |> maybe_put(:source_ip, source_ip)

    {:ok, event} =
      %AgentEvent{workspace_id: workspace_id, registered_agent_id: registered_agent_id}
      |> AgentEvent.changeset(event_attrs)
      |> Ecto.Changeset.change(server_fields)
      |> Repo.insert()

    event
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
