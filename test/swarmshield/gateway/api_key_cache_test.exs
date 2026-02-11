defmodule Swarmshield.Gateway.ApiKeyCacheTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Gateway.ApiKeyCache

  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures

  # async: false because ApiKeyCache uses shared ETS table

  setup do
    workspace = workspace_fixture()
    %{workspace: workspace}
  end

  describe "get_agent_by_key_hash/1" do
    test "cache hit returns agent info", %{workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "cached-agent"})

      # Refresh cache so agent is loaded
      ApiKeyCache.refresh_all()
      _ = :sys.get_state(ApiKeyCache)
      Process.sleep(200)

      assert {:ok, info} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)
      assert info.agent_id == agent.id
      assert info.workspace_id == workspace.id
      assert info.agent_name == "cached-agent"
      assert info.status == :active
    end

    test "cache miss queries database and caches result", %{workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "miss-agent"})

      # Don't refresh - force a cache miss
      # The lookup will hit the DB and cache the result
      assert {:ok, info} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)
      assert info.agent_id == agent.id

      # Second lookup should be a cache hit (no DB query)
      assert {:ok, info2} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)
      assert info2.agent_id == agent.id
    end

    test "non-existent key returns :not_found", %{workspace: _workspace} do
      fake_hash = :crypto.hash(:sha256, "nonexistent-key") |> Base.encode64()
      assert {:error, :not_found} = ApiKeyCache.get_agent_by_key_hash(fake_hash)
    end

    test "negative cache prevents repeated DB lookups for invalid keys" do
      fake_hash = :crypto.hash(:sha256, "brute-force-key") |> Base.encode64()

      # First lookup - DB miss, negative cached
      assert {:error, :not_found} = ApiKeyCache.get_agent_by_key_hash(fake_hash)

      # Second lookup - should hit negative cache (not DB)
      assert {:error, :not_found} = ApiKeyCache.get_agent_by_key_hash(fake_hash)
    end

    test "suspended agent cached but returns :suspended", %{workspace: workspace} do
      agent =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "suspended-agent",
          status: :suspended
        })

      # Write-through on miss should cache the suspended agent
      assert {:error, :suspended} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)

      # Second lookup from cache also returns suspended
      assert {:error, :suspended} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)
    end

    test "nil key returns :not_found" do
      assert {:error, :not_found} = ApiKeyCache.get_agent_by_key_hash(nil)
    end
  end

  describe "invalidate_agent/1" do
    test "removes cache entry for agent", %{workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "to-invalidate"})

      # Populate cache
      assert {:ok, _info} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)

      # Invalidate
      assert :ok = ApiKeyCache.invalidate_agent(agent.id)

      # Next lookup is a cache miss (but will hit DB and re-cache)
      assert {:ok, info} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)
      assert info.agent_id == agent.id
    end
  end

  describe "invalidate_key/1" do
    test "removes specific key hash entry", %{workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "key-invalidate"})

      # Populate cache
      assert {:ok, _info} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)

      # Invalidate by key
      assert :ok = ApiKeyCache.invalidate_key(agent.api_key_hash)

      # Re-lookup works (DB fallback)
      assert {:ok, _info} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)
    end
  end

  describe "PubSub-driven invalidation" do
    test "agent status change invalidates cache", %{workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "pubsub-status"})

      # Populate cache
      assert {:ok, _info} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)

      # Simulate PubSub message
      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "agents:status_changed",
        {:agent_status_changed, agent.id}
      )

      # Give GenServer time to process
      Process.sleep(50)

      # Cache entry should be invalidated (will re-fetch from DB)
      assert {:ok, info} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)
      assert info.agent_id == agent.id
    end

    test "agent deletion invalidates cache", %{workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "pubsub-delete"})

      # Populate cache
      assert {:ok, _info} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)

      # Simulate PubSub deletion message
      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "agents:deleted",
        {:agent_deleted, agent.id}
      )

      Process.sleep(50)

      # Cache invalidated - but agent still exists in DB so will re-cache
      assert {:ok, _info} = ApiKeyCache.get_agent_by_key_hash(agent.api_key_hash)
    end

    test "key regeneration invalidates old hash", %{workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "pubsub-regen"})
      old_hash = agent.api_key_hash

      # Populate cache with old hash
      assert {:ok, _info} = ApiKeyCache.get_agent_by_key_hash(old_hash)

      # Simulate key regeneration PubSub message
      Phoenix.PubSub.broadcast(
        Swarmshield.PubSub,
        "agents:key_regenerated",
        {:agent_key_regenerated, agent.id, old_hash}
      )

      Process.sleep(50)

      # Old hash cache entry removed (DB lookup with old hash will find agent since
      # we didn't actually regenerate the key in DB - just testing cache invalidation)
      assert {:ok, _} = ApiKeyCache.get_agent_by_key_hash(old_hash)
    end
  end

  describe "refresh_all/0" do
    test "reloads all active agents", %{workspace: workspace} do
      agent1 =
        registered_agent_fixture(%{workspace_id: workspace.id, name: "refresh-1"})

      agent2 =
        registered_agent_fixture(%{workspace_id: workspace.id, name: "refresh-2"})

      _suspended =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          name: "refresh-suspended",
          status: :suspended
        })

      ApiKeyCache.refresh_all()
      _ = :sys.get_state(ApiKeyCache)
      Process.sleep(200)

      # Active agents should be cached
      assert {:ok, info1} = ApiKeyCache.get_agent_by_key_hash(agent1.api_key_hash)
      assert info1.agent_id == agent1.id

      assert {:ok, info2} = ApiKeyCache.get_agent_by_key_hash(agent2.api_key_hash)
      assert info2.agent_id == agent2.id
    end
  end

  describe "cross-workspace isolation" do
    test "agents from different workspaces are cached independently" do
      workspace1 = workspace_fixture()
      workspace2 = workspace_fixture()

      agent1 =
        registered_agent_fixture(%{workspace_id: workspace1.id, name: "ws1-agent"})

      agent2 =
        registered_agent_fixture(%{workspace_id: workspace2.id, name: "ws2-agent"})

      assert {:ok, info1} = ApiKeyCache.get_agent_by_key_hash(agent1.api_key_hash)
      assert {:ok, info2} = ApiKeyCache.get_agent_by_key_hash(agent2.api_key_hash)

      assert info1.workspace_id == workspace1.id
      assert info2.workspace_id == workspace2.id
      assert info1.workspace_id != info2.workspace_id
    end
  end
end
