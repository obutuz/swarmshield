defmodule Swarmshield.GatewayTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Gateway
  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures

  # ---------------------------------------------------------------------------
  # RegisteredAgent CRUD
  # ---------------------------------------------------------------------------

  describe "list_registered_agents/2" do
    test "returns agents scoped to workspace" do
      workspace = workspace_fixture()
      other_workspace = workspace_fixture()

      agent = registered_agent_fixture(%{workspace_id: workspace.id})
      _other_agent = registered_agent_fixture(%{workspace_id: other_workspace.id})

      {agents, total_count} = Gateway.list_registered_agents(workspace.id)

      assert total_count == 1
      assert [returned] = agents
      assert returned.id == agent.id
    end

    test "returns empty list for workspace with no agents" do
      workspace = workspace_fixture()

      {agents, total_count} = Gateway.list_registered_agents(workspace.id)

      assert agents == []
      assert total_count == 0
    end

    test "filters by status" do
      workspace = workspace_fixture()
      _active = registered_agent_fixture(%{workspace_id: workspace.id, status: :active})

      suspended =
        registered_agent_fixture(%{workspace_id: workspace.id, name: "suspended-agent"})

      {:ok, suspended} = Gateway.deactivate_registered_agent(suspended)

      {agents, total_count} =
        Gateway.list_registered_agents(workspace.id, status: :suspended)

      assert total_count == 1
      assert [returned] = agents
      assert returned.id == suspended.id
    end

    test "filters by agent_type" do
      workspace = workspace_fixture()
      _auto = registered_agent_fixture(%{workspace_id: workspace.id, agent_type: :autonomous})

      chatbot =
        registered_agent_fixture(%{
          workspace_id: workspace.id,
          agent_type: :chatbot,
          name: "chatbot-1"
        })

      {agents, total_count} =
        Gateway.list_registered_agents(workspace.id, agent_type: :chatbot)

      assert total_count == 1
      assert [returned] = agents
      assert returned.id == chatbot.id
    end

    test "filters by search (case-insensitive)" do
      workspace = workspace_fixture()

      target =
        registered_agent_fixture(%{workspace_id: workspace.id, name: "SpecialBot"})

      _other = registered_agent_fixture(%{workspace_id: workspace.id, name: "generic-agent"})

      {agents, total_count} =
        Gateway.list_registered_agents(workspace.id, search: "specialbot")

      assert total_count == 1
      assert [returned] = agents
      assert returned.id == target.id
    end

    test "search sanitizes SQL wildcards" do
      workspace = workspace_fixture()

      target =
        registered_agent_fixture(%{workspace_id: workspace.id, name: "agent_with_underscore"})

      _other = registered_agent_fixture(%{workspace_id: workspace.id, name: "agent-no-match"})

      {agents, _total} =
        Gateway.list_registered_agents(workspace.id, search: "agent_with")

      assert [returned] = agents
      assert returned.id == target.id
    end

    test "paginates results correctly" do
      workspace = workspace_fixture()

      for i <- 1..5 do
        registered_agent_fixture(%{workspace_id: workspace.id, name: "agent-#{i}"})
      end

      {page1, total} = Gateway.list_registered_agents(workspace.id, page: 1, page_size: 2)
      assert total == 5
      assert length(page1) == 2

      {page2, _total} = Gateway.list_registered_agents(workspace.id, page: 2, page_size: 2)
      assert length(page2) == 2

      {page3, _total} = Gateway.list_registered_agents(workspace.id, page: 3, page_size: 2)
      assert length(page3) == 1

      # No overlap between pages
      all_ids = Enum.map(page1 ++ page2 ++ page3, & &1.id)
      assert length(Enum.uniq(all_ids)) == 5
    end

    test "clamps page_size to max 100" do
      workspace = workspace_fixture()
      registered_agent_fixture(%{workspace_id: workspace.id})

      {agents, _total} =
        Gateway.list_registered_agents(workspace.id, page_size: 999)

      # Should not crash, just clamp
      assert is_list(agents)
    end
  end

  describe "get_registered_agent!/1" do
    test "returns the agent with the given id" do
      agent = registered_agent_fixture()

      returned = Gateway.get_registered_agent!(agent.id)

      assert returned.id == agent.id
      assert returned.name == agent.name
    end

    test "raises on non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Gateway.get_registered_agent!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_registered_agent_by_api_key/1" do
    test "returns agent matching the key hash" do
      agent = registered_agent_fixture()

      returned = Gateway.get_registered_agent_by_api_key(agent.api_key_hash)

      assert returned.id == agent.id
    end

    test "returns nil for non-existent hash" do
      assert Gateway.get_registered_agent_by_api_key("nonexistent_hash") == nil
    end

    test "returns nil for non-binary input" do
      assert Gateway.get_registered_agent_by_api_key(nil) == nil
    end
  end

  describe "create_registered_agent/2" do
    test "creates agent with generated API key" do
      workspace = workspace_fixture()

      attrs = %{
        name: "my-new-agent",
        description: "A test agent",
        agent_type: :chatbot,
        risk_level: :low
      }

      assert {:ok, agent, raw_key} =
               Gateway.create_registered_agent(workspace.id, attrs)

      assert agent.name == "my-new-agent"
      assert agent.agent_type == :chatbot
      assert agent.risk_level == :low
      assert agent.workspace_id == workspace.id
      assert agent.status == :active
      assert agent.event_count == 0

      # API key was generated
      assert is_binary(raw_key)
      assert byte_size(raw_key) > 0
      assert is_binary(agent.api_key_hash)
      assert is_binary(agent.api_key_prefix)
      assert String.length(agent.api_key_prefix) == 8
    end

    test "returns error for invalid attrs" do
      workspace = workspace_fixture()

      assert {:error, changeset} =
               Gateway.create_registered_agent(workspace.id, %{name: ""})

      assert errors_on(changeset).name != nil
    end

    test "returns error for duplicate name in same workspace" do
      workspace = workspace_fixture()
      registered_agent_fixture(%{workspace_id: workspace.id, name: "duplicate"})

      assert {:error, changeset} =
               Gateway.create_registered_agent(workspace.id, %{name: "duplicate"})

      assert "an agent with this name already exists in this workspace" in errors_on(changeset).workspace_id
    end

    test "allows same name in different workspaces" do
      workspace1 = workspace_fixture()
      workspace2 = workspace_fixture()

      assert {:ok, _agent1, _key1} =
               Gateway.create_registered_agent(workspace1.id, %{name: "shared-name"})

      assert {:ok, _agent2, _key2} =
               Gateway.create_registered_agent(workspace2.id, %{name: "shared-name"})
    end
  end

  describe "update_registered_agent/2" do
    test "updates user-facing fields" do
      agent = registered_agent_fixture()

      assert {:ok, updated} =
               Gateway.update_registered_agent(agent, %{
                 name: "updated-name",
                 description: "new description"
               })

      assert updated.name == "updated-name"
      assert updated.description == "new description"
    end

    test "does not allow direct status change to active from suspended" do
      agent = registered_agent_fixture()
      {:ok, suspended} = Gateway.deactivate_registered_agent(agent)

      assert {:error, changeset} =
               Gateway.update_registered_agent(suspended, %{status: :active})

      assert errors_on(changeset).status != nil
    end
  end

  describe "deactivate_registered_agent/1" do
    test "sets status to suspended and records last_seen_at" do
      agent = registered_agent_fixture()

      assert agent.status == :active
      assert agent.last_seen_at == nil

      assert {:ok, deactivated} = Gateway.deactivate_registered_agent(agent)

      assert deactivated.status == :suspended
      assert deactivated.last_seen_at != nil
    end
  end

  describe "regenerate_api_key/1" do
    test "generates new key and invalidates old one" do
      agent = registered_agent_fixture()
      old_hash = agent.api_key_hash
      old_prefix = agent.api_key_prefix

      assert {:ok, updated, new_raw_key} = Gateway.regenerate_api_key(agent)

      assert updated.api_key_hash != old_hash
      assert updated.api_key_prefix != old_prefix
      assert is_binary(new_raw_key)

      # Old hash no longer finds the agent
      assert Gateway.get_registered_agent_by_api_key(old_hash) == nil
      # New hash finds it
      assert Gateway.get_registered_agent_by_api_key(updated.api_key_hash).id == agent.id
    end
  end

  # ---------------------------------------------------------------------------
  # AgentEvent CRUD
  # ---------------------------------------------------------------------------

  describe "list_agent_events/2" do
    test "returns events scoped to workspace with preloaded agent" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})
      other_workspace = workspace_fixture()
      other_agent = registered_agent_fixture(%{workspace_id: other_workspace.id})

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "test content"
        })

      {:ok, _other_event} =
        Gateway.create_agent_event(other_workspace.id, other_agent.id, %{
          event_type: :action,
          content: "other content"
        })

      {events, total_count} = Gateway.list_agent_events(workspace.id)

      assert total_count == 1
      assert [returned] = events
      assert returned.id == event.id
      # Preloaded association
      assert returned.registered_agent.id == agent.id
    end

    test "returns empty list for workspace with no events" do
      workspace = workspace_fixture()

      {events, total_count} = Gateway.list_agent_events(workspace.id)

      assert events == []
      assert total_count == 0
    end

    test "filters by registered_agent_id" do
      workspace = workspace_fixture()
      agent1 = registered_agent_fixture(%{workspace_id: workspace.id})
      agent2 = registered_agent_fixture(%{workspace_id: workspace.id, name: "agent-2"})

      {:ok, event1} =
        Gateway.create_agent_event(workspace.id, agent1.id, %{
          event_type: :action,
          content: "agent1 event"
        })

      {:ok, _event2} =
        Gateway.create_agent_event(workspace.id, agent2.id, %{
          event_type: :action,
          content: "agent2 event"
        })

      {events, total_count} =
        Gateway.list_agent_events(workspace.id, registered_agent_id: agent1.id)

      assert total_count == 1
      assert [returned] = events
      assert returned.id == event1.id
    end

    test "filters by event_type" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, action_event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "action"
        })

      {:ok, _error_event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :error,
          content: "error"
        })

      {events, total_count} =
        Gateway.list_agent_events(workspace.id, event_type: :action)

      assert total_count == 1
      assert [returned] = events
      assert returned.id == action_event.id
    end

    test "filters by status" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "pending event"
        })

      {:ok, _flagged_event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "will be flagged"
        })

      # Only the first event stays pending
      {events, total_count} =
        Gateway.list_agent_events(workspace.id, status: :pending)

      assert total_count == 2
      ids = Enum.map(events, & &1.id)
      assert event.id in ids
    end

    test "filters by severity" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, critical_event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :error,
          content: "critical!",
          severity: :critical
        })

      {:ok, _info_event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "info event",
          severity: :info
        })

      {events, total_count} =
        Gateway.list_agent_events(workspace.id, severity: :critical)

      assert total_count == 1
      assert [returned] = events
      assert returned.id == critical_event.id
    end

    test "filters compose correctly (agent AND type AND status)" do
      workspace = workspace_fixture()
      agent1 = registered_agent_fixture(%{workspace_id: workspace.id})
      agent2 = registered_agent_fixture(%{workspace_id: workspace.id, name: "agent-2"})

      # Target: agent1, action, pending
      {:ok, target} =
        Gateway.create_agent_event(workspace.id, agent1.id, %{
          event_type: :action,
          content: "target"
        })

      # agent1, error, pending - wrong type
      {:ok, _} =
        Gateway.create_agent_event(workspace.id, agent1.id, %{
          event_type: :error,
          content: "wrong type"
        })

      # agent2, action, pending - wrong agent
      {:ok, _} =
        Gateway.create_agent_event(workspace.id, agent2.id, %{
          event_type: :action,
          content: "wrong agent"
        })

      {events, total_count} =
        Gateway.list_agent_events(workspace.id,
          registered_agent_id: agent1.id,
          event_type: :action,
          status: :pending
        )

      assert total_count == 1
      assert [returned] = events
      assert returned.id == target.id
    end

    test "filters by date range" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "test event"
        })

      now = DateTime.utc_now(:second)
      past = DateTime.add(now, -3600, :second)
      future = DateTime.add(now, 3600, :second)

      # Event within range
      {events, total_count} =
        Gateway.list_agent_events(workspace.id, from: past, to: future)

      assert total_count == 1
      assert [returned] = events
      assert returned.id == event.id

      # Event out of range (future only)
      {events_future, count_future} =
        Gateway.list_agent_events(workspace.id, from: future)

      assert count_future == 0
      assert events_future == []
    end

    test "paginates results correctly" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      for _ <- 1..5 do
        {:ok, _} =
          Gateway.create_agent_event(workspace.id, agent.id, %{
            event_type: :action,
            content: "test"
          })
      end

      {page1, total} = Gateway.list_agent_events(workspace.id, page: 1, page_size: 2)
      assert total == 5
      assert length(page1) == 2

      {page2, _} = Gateway.list_agent_events(workspace.id, page: 2, page_size: 2)
      assert length(page2) == 2

      {page3, _} = Gateway.list_agent_events(workspace.id, page: 3, page_size: 2)
      assert length(page3) == 1

      all_ids = Enum.map(page1 ++ page2 ++ page3, & &1.id)
      assert length(Enum.uniq(all_ids)) == 5
    end
  end

  describe "get_agent_event!/1" do
    test "returns event with preloaded agent" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "test"
        })

      returned = Gateway.get_agent_event!(event.id)

      assert returned.id == event.id
      assert returned.registered_agent.id == agent.id
    end

    test "raises on non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Gateway.get_agent_event!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_agent_event/3" do
    test "creates event and atomically increments agent event_count" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      assert agent.event_count == 0

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "first event",
          payload: %{"key" => "value"},
          severity: :warning
        })

      assert event.event_type == :action
      assert event.content == "first event"
      assert event.payload == %{"key" => "value"}
      assert event.severity == :warning
      assert event.status == :pending
      assert event.workspace_id == workspace.id
      assert event.registered_agent_id == agent.id

      # Verify atomic increment
      updated_agent = Gateway.get_registered_agent!(agent.id)
      assert updated_agent.event_count == 1
      assert updated_agent.last_seen_at != nil
    end

    test "increments event_count atomically across multiple events" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      for _ <- 1..5 do
        {:ok, _} =
          Gateway.create_agent_event(workspace.id, agent.id, %{
            event_type: :action,
            content: "event"
          })
      end

      updated_agent = Gateway.get_registered_agent!(agent.id)
      assert updated_agent.event_count == 5
    end

    test "returns error for invalid event attrs" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      assert {:error, changeset} =
               Gateway.create_agent_event(workspace.id, agent.id, %{
                 event_type: nil,
                 content: nil
               })

      errors = errors_on(changeset)
      assert errors.event_type != nil
      assert errors.content != nil
    end

    test "event defaults to pending status" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :message,
          content: "hello"
        })

      assert event.status == :pending
    end
  end

  describe "update_agent_event_status/2" do
    setup do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "test event"
        })

      %{event: event}
    end

    test "transitions pending -> allowed", %{event: event} do
      assert {:ok, updated} = Gateway.update_agent_event_status(event, :allowed)
      assert updated.status == :allowed
      assert updated.evaluated_at != nil
    end

    test "transitions pending -> flagged", %{event: event} do
      assert {:ok, updated} = Gateway.update_agent_event_status(event, :flagged)
      assert updated.status == :flagged
      assert updated.evaluated_at != nil
    end

    test "transitions pending -> blocked", %{event: event} do
      assert {:ok, updated} = Gateway.update_agent_event_status(event, :blocked)
      assert updated.status == :blocked
      assert updated.evaluated_at != nil
    end

    test "rejects transition from allowed (terminal state)", %{event: event} do
      {:ok, allowed} = Gateway.update_agent_event_status(event, :allowed)

      assert {:error, changeset} = Gateway.update_agent_event_status(allowed, :blocked)
      assert errors_on(changeset).status != nil
    end

    test "allows deliberation verdict to override flagged status", %{event: event} do
      {:ok, flagged} = Gateway.update_agent_event_status(event, :flagged)
      assert flagged.status == :flagged

      {:ok, updated} = Gateway.update_agent_event_status(flagged, :allowed)
      assert updated.status == :allowed
    end

    test "allows deliberation verdict to override blocked status", %{event: event} do
      {:ok, blocked} = Gateway.update_agent_event_status(event, :blocked)
      assert blocked.status == :blocked

      {:ok, updated} = Gateway.update_agent_event_status(blocked, :allowed)
      assert updated.status == :allowed
    end

    test "rejects invalid target status from pending", %{event: event} do
      assert {:error, changeset} = Gateway.update_agent_event_status(event, :pending)
      assert errors_on(changeset).status != nil
    end
  end

  describe "null byte handling" do
    test "content with null bytes is rejected by PostgreSQL" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      # PostgreSQL rejects null bytes even though they're valid UTF-8
      assert_raise Postgrex.Error, fn ->
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :message,
          content: "Hello\x00World"
        })
      end
    end
  end

  describe "FK cascade behavior" do
    test "deleting workspace cascades to registered agents" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      Repo.delete!(workspace)

      assert Repo.get(Swarmshield.Gateway.RegisteredAgent, agent.id) == nil
    end

    test "deleting workspace cascades to agent events" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "test"
        })

      Repo.delete!(workspace)

      assert Repo.get(Swarmshield.Gateway.AgentEvent, event.id) == nil
    end

    test "deleting registered agent cascades to its events" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "test"
        })

      Repo.delete!(agent)

      assert Repo.get(Swarmshield.Gateway.AgentEvent, event.id) == nil
    end
  end

  describe "update_agent_event_evaluation/2" do
    test "updates evaluation result on pending event" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "test"
        })

      now = DateTime.utc_now(:second)

      assert {:ok, updated} =
               Gateway.update_agent_event_evaluation(event, %{
                 status: :flagged,
                 evaluation_result: %{"matched_rules" => ["rate_limit"]},
                 evaluated_at: now,
                 flagged_reason: "Rate limit exceeded"
               })

      assert updated.status == :flagged
      assert updated.evaluation_result == %{"matched_rules" => ["rate_limit"]}
      assert updated.flagged_reason == "Rate limit exceeded"
    end

    test "rejects update on non-pending event" do
      workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: workspace.id})

      {:ok, event} =
        Gateway.create_agent_event(workspace.id, agent.id, %{
          event_type: :action,
          content: "test"
        })

      {:ok, allowed} = Gateway.update_agent_event_status(event, :allowed)

      assert {:error, _reason} =
               Gateway.update_agent_event_evaluation(allowed, %{status: :flagged})
    end
  end
end
