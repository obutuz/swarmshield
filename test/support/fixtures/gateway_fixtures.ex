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
end
