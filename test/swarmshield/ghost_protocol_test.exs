defmodule Swarmshield.GhostProtocolTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.GhostProtocol
  alias Swarmshield.GhostProtocol.Config

  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures
  import Swarmshield.GhostProtocolFixtures

  setup do
    workspace = workspace_fixture()
    %{workspace: workspace}
  end

  # ---------------------------------------------------------------------------
  # Config CRUD
  # ---------------------------------------------------------------------------

  describe "list_configs/2" do
    test "returns paginated configs for workspace", %{workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      {configs, total_count} = GhostProtocol.list_configs(workspace.id)

      assert total_count == 1
      [found] = configs
      assert found.id == config.id
      assert Ecto.assoc_loaded?(found.workflows)
    end

    test "does not return configs from other workspaces", %{workspace: workspace} do
      other = workspace_fixture()
      ghost_protocol_config_fixture(%{workspace_id: other.id})

      {configs, total_count} = GhostProtocol.list_configs(workspace.id)

      assert total_count == 0
      assert configs == []
    end

    test "paginates results", %{workspace: workspace} do
      for _i <- 1..5, do: ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      {configs, total_count} = GhostProtocol.list_configs(workspace.id, page: 1, page_size: 2)

      assert total_count == 5
      assert length(configs) == 2
    end
  end

  describe "get_config!/1" do
    test "returns config with preloaded workflows", %{workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      found = GhostProtocol.get_config!(config.id)

      assert found.id == config.id
      assert Ecto.assoc_loaded?(found.workflows)
    end

    test "raises for missing id" do
      assert_raise Ecto.NoResultsError, fn ->
        GhostProtocol.get_config!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_config_for_workspace!/2" do
    test "returns config scoped to workspace", %{workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})
      found = GhostProtocol.get_config_for_workspace!(config.id, workspace.id)
      assert found.id == config.id
    end

    test "raises for config in different workspace", %{workspace: workspace} do
      other = workspace_fixture()
      config = ghost_protocol_config_fixture(%{workspace_id: other.id})

      assert_raise Ecto.NoResultsError, fn ->
        GhostProtocol.get_config_for_workspace!(config.id, workspace.id)
      end
    end
  end

  describe "create_config/2" do
    test "creates config with valid attrs", %{workspace: workspace} do
      assert {:ok, %Config{} = config} =
               GhostProtocol.create_config(workspace.id, %{
                 name: "Test Config",
                 wipe_strategy: :immediate,
                 wipe_fields: ["input_content", "metadata"],
                 max_session_duration_seconds: 300,
                 crypto_shred: true
               })

      assert config.name == "Test Config"
      assert config.wipe_strategy == :immediate
      assert config.crypto_shred == true
      assert config.workspace_id == workspace.id
      assert config.slug == "test-config"
    end

    test "returns error with invalid attrs", %{workspace: workspace} do
      assert {:error, %Ecto.Changeset{}} =
               GhostProtocol.create_config(workspace.id, %{name: ""})
    end

    test "broadcasts PubSub on creation", %{workspace: workspace} do
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "ghost_protocol:#{workspace.id}")

      {:ok, config} =
        GhostProtocol.create_config(workspace.id, %{
          name: "Broadcast Test",
          wipe_strategy: :immediate,
          max_session_duration_seconds: 60
        })

      config_id = config.id
      assert_receive {:config_created, ^config_id}
    end
  end

  describe "update_config/2" do
    test "updates config with valid attrs", %{workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      assert {:ok, updated} =
               GhostProtocol.update_config(config, %{
                 name: "Updated Name",
                 crypto_shred: true
               })

      assert updated.name == "Updated Name"
      assert updated.crypto_shred == true
    end

    test "broadcasts PubSub on update", %{workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "ghost_protocol:#{workspace.id}")

      {:ok, _updated} = GhostProtocol.update_config(config, %{name: "Updated"})

      config_id = config.id
      assert_receive {:config_updated, ^config_id}
    end
  end

  describe "delete_config/1" do
    test "deletes config with no linked workflows", %{workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      assert {:ok, %Config{}} = GhostProtocol.delete_config(config)

      assert_raise Ecto.NoResultsError, fn ->
        GhostProtocol.get_config!(config.id)
      end
    end

    test "returns error when workflows are linked", %{workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      _workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: config.id
        })

      assert {:error, :has_linked_workflows} = GhostProtocol.delete_config(config)

      # Config still exists
      assert GhostProtocol.get_config!(config.id).id == config.id
    end

    test "broadcasts PubSub on deletion", %{workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "ghost_protocol:#{workspace.id}")

      {:ok, _deleted} = GhostProtocol.delete_config(config)

      config_id = config.id
      assert_receive {:config_deleted, ^config_id}
    end
  end

  # ---------------------------------------------------------------------------
  # Ephemeral Sessions
  # ---------------------------------------------------------------------------

  describe "list_active_ephemeral_sessions/1" do
    test "returns active sessions with ghost_protocol_config", %{workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: config.id
        })

      _session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :analyzing
        })

      sessions = GhostProtocol.list_active_ephemeral_sessions(workspace.id)

      assert length(sessions) == 1
      [found] = sessions
      assert found.status == :analyzing
      assert Ecto.assoc_loaded?(found.workflow)
    end

    test "excludes completed/failed/timed_out sessions", %{workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: config.id
        })

      _completed =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :completed
        })

      sessions = GhostProtocol.list_active_ephemeral_sessions(workspace.id)
      assert sessions == []
    end

    test "excludes non-ephemeral sessions", %{workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})

      _session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :analyzing
        })

      sessions = GhostProtocol.list_active_ephemeral_sessions(workspace.id)
      assert sessions == []
    end
  end

  describe "get_session_with_ghost_config/1" do
    test "returns session with ghost_protocol_config preloaded", %{workspace: workspace} do
      config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: config.id
        })

      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id
        })

      found = GhostProtocol.get_session_with_ghost_config(session.id)

      assert found.id == session.id
      assert Ecto.assoc_loaded?(found.workflow)
      assert found.workflow.ghost_protocol_config_id == config.id
    end

    test "returns nil for non-ephemeral session ghost_protocol_config", %{workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})

      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id
        })

      found = GhostProtocol.get_session_with_ghost_config(session.id)

      assert found.id == session.id
      assert found.workflow.ghost_protocol_config_id == nil
    end

    test "returns nil for missing session" do
      assert GhostProtocol.get_session_with_ghost_config(Ecto.UUID.generate()) == nil
    end
  end
end
