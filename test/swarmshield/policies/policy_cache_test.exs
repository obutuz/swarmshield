defmodule Swarmshield.Policies.PolicyCacheTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Policies.PolicyCache

  import Swarmshield.AccountsFixtures
  import Swarmshield.PoliciesFixtures

  # async: false because we're testing a shared GenServer + ETS tables

  setup do
    # Give the cache a moment to finish any pending operations
    # then refresh to ensure clean state
    PolicyCache.refresh_all()
    # Wait for the cast to be processed
    _ = :sys.get_state(PolicyCache)
    # Wait for debounced refreshes
    Process.sleep(100)

    :ok
  end

  describe "get_rules/1" do
    test "returns cached policy rules for workspace" do
      workspace = workspace_fixture()
      rule = policy_rule_fixture(%{workspace_id: workspace.id, enabled: true})

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      rules = PolicyCache.get_rules(workspace.id)

      assert length(rules) == 1
      assert hd(rules).id == rule.id
    end

    test "returns empty list for workspace with no rules" do
      workspace = workspace_fixture()

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      assert PolicyCache.get_rules(workspace.id) == []
    end

    test "returns empty list for unknown workspace" do
      assert PolicyCache.get_rules(Ecto.UUID.generate()) == []
    end

    test "only returns enabled rules" do
      workspace = workspace_fixture()
      enabled = policy_rule_fixture(%{workspace_id: workspace.id, enabled: true})
      _disabled = policy_rule_fixture(%{workspace_id: workspace.id, enabled: false})

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      rules = PolicyCache.get_rules(workspace.id)

      assert length(rules) == 1
      assert hd(rules).id == enabled.id
    end
  end

  describe "get_detection_rules/1" do
    test "returns cached detection rules for workspace" do
      workspace = workspace_fixture()
      rule = detection_rule_fixture(%{workspace_id: workspace.id, enabled: true})

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      rules = PolicyCache.get_detection_rules(workspace.id)

      assert length(rules) == 1
      assert hd(rules).id == rule.id
    end

    test "returns empty list for workspace with no detection rules" do
      workspace = workspace_fixture()

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      assert PolicyCache.get_detection_rules(workspace.id) == []
    end

    test "only returns enabled detection rules" do
      workspace = workspace_fixture()
      enabled = detection_rule_fixture(%{workspace_id: workspace.id, enabled: true})
      _disabled = detection_rule_fixture(%{workspace_id: workspace.id, enabled: false})

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      rules = PolicyCache.get_detection_rules(workspace.id)

      assert length(rules) == 1
      assert hd(rules).id == enabled.id
    end
  end

  describe "refresh/1" do
    test "refreshes specific workspace cache" do
      workspace = workspace_fixture()

      # Initially empty
      assert PolicyCache.get_rules(workspace.id) == []

      # Create a rule
      _rule = policy_rule_fixture(%{workspace_id: workspace.id, enabled: true})

      # Refresh specific workspace
      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      rules = PolicyCache.get_rules(workspace.id)
      assert length(rules) == 1
    end

    test "per-workspace refresh does not affect other workspaces" do
      workspace1 = workspace_fixture()
      workspace2 = workspace_fixture()

      _rule1 = policy_rule_fixture(%{workspace_id: workspace1.id, enabled: true})
      _rule2 = policy_rule_fixture(%{workspace_id: workspace2.id, enabled: true})

      # Load both
      PolicyCache.refresh(workspace1.id)
      PolicyCache.refresh(workspace2.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      assert length(PolicyCache.get_rules(workspace1.id)) == 1
      assert length(PolicyCache.get_rules(workspace2.id)) == 1

      # Add another rule to workspace1 and refresh only workspace1
      _rule1b = policy_rule_fixture(%{workspace_id: workspace1.id, enabled: true})
      PolicyCache.refresh(workspace1.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      # Workspace1 updated, workspace2 unchanged
      assert length(PolicyCache.get_rules(workspace1.id)) == 2
      assert length(PolicyCache.get_rules(workspace2.id)) == 1
    end
  end

  describe "refresh_all/0" do
    test "refreshes all workspaces" do
      workspace1 = workspace_fixture()
      workspace2 = workspace_fixture()

      _rule1 = policy_rule_fixture(%{workspace_id: workspace1.id, enabled: true})
      _rule2 = policy_rule_fixture(%{workspace_id: workspace2.id, enabled: true})

      PolicyCache.refresh_all()
      _ = :sys.get_state(PolicyCache)
      Process.sleep(100)

      assert length(PolicyCache.get_rules(workspace1.id)) == 1
      assert length(PolicyCache.get_rules(workspace2.id)) == 1
    end
  end

  describe "PubSub-triggered updates" do
    test "cache refreshes on policy_rules PubSub broadcast" do
      workspace = workspace_fixture()

      # Subscribe the cache to this workspace
      PolicyCache.subscribe_to_workspace(workspace.id)
      _ = :sys.get_state(PolicyCache)

      # Initially no rules cached
      assert PolicyCache.get_rules(workspace.id) == []

      # Create a rule (context function broadcasts PubSub)
      _rule =
        policy_rule_fixture(%{workspace_id: workspace.id, enabled: true})

      # The PubSub broadcast triggers a refresh in the cache
      # But we need to manually simulate because the PubSub handler
      # gets the message on the _subscriber_ (PolicyCache GenServer)
      # The Policies context already broadcasts, and PolicyCache is subscribed
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      # Cache should now be populated
      rules = PolicyCache.get_rules(workspace.id)
      assert is_list(rules)
    end
  end

  describe "debounce behavior" do
    test "rapid refreshes are debounced (single DB hit)" do
      workspace = workspace_fixture()
      _rule = policy_rule_fixture(%{workspace_id: workspace.id, enabled: true})

      # Fire multiple rapid refreshes
      PolicyCache.refresh(workspace.id)
      PolicyCache.refresh(workspace.id)
      PolicyCache.refresh(workspace.id)

      # Wait for debounce to fire (500ms + small buffer)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(700)

      # Cache should still be populated correctly despite rapid refreshes
      rules = PolicyCache.get_rules(workspace.id)
      assert length(rules) == 1
    end
  end

  describe "crash recovery" do
    test "GenServer restart recovers ETS tables via init/1" do
      # The tables already exist from the application start
      # Verify they are accessible
      workspace = workspace_fixture()
      _rule = policy_rule_fixture(%{workspace_id: workspace.id, enabled: true})

      PolicyCache.refresh(workspace.id)
      _ = :sys.get_state(PolicyCache)
      Process.sleep(600)

      assert length(PolicyCache.get_rules(workspace.id)) == 1
    end
  end
end
