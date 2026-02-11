defmodule Swarmshield.GhostProtocolFixtures do
  @moduledoc """
  Test helpers for creating entities in the `Swarmshield.GhostProtocol` context.
  """

  alias Swarmshield.GhostProtocol.Config
  alias Swarmshield.Repo

  import Swarmshield.AccountsFixtures, only: [workspace_fixture: 0]

  def unique_ghost_protocol_name, do: "ghost-config-#{System.unique_integer([:positive])}"

  def valid_ghost_protocol_config_attributes(attrs \\ %{}) do
    name = unique_ghost_protocol_name()

    Enum.into(attrs, %{
      name: name,
      slug: String.downcase(name),
      wipe_strategy: :immediate,
      wipe_delay_seconds: 0,
      wipe_fields: ["input_content", "deliberation_messages"],
      retain_verdict: true,
      retain_audit: true,
      max_session_duration_seconds: 300,
      auto_terminate_on_expiry: true,
      crypto_shred: false,
      enabled: true,
      metadata: %{}
    })
  end

  @doc """
  Creates a ghost protocol config with a workspace.

  Pass `workspace_id` in attrs to use an existing workspace,
  or one will be created automatically.
  """
  def ghost_protocol_config_fixture(attrs \\ %{}) do
    {workspace_id, attrs} =
      case Map.pop(attrs, :workspace_id) do
        {nil, rest} ->
          workspace = workspace_fixture()
          {workspace.id, rest}

        {wid, rest} ->
          {wid, rest}
      end

    config_attrs = valid_ghost_protocol_config_attributes(attrs)

    {:ok, config} =
      %Config{workspace_id: workspace_id}
      |> Config.changeset(config_attrs)
      |> Repo.insert()

    config
  end
end
