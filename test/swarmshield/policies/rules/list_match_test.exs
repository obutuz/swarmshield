defmodule Swarmshield.Policies.Rules.ListMatchTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Policies.Rules.ListMatch

  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.PoliciesFixtures

  setup do
    workspace = workspace_fixture()
    agent = registered_agent_fixture(%{workspace_id: workspace.id, name: "test-bot"})

    event =
      agent_event_fixture(%{
        workspace_id: workspace.id,
        registered_agent_id: agent.id,
        event_type: :action,
        content: "test content"
      })
      |> Swarmshield.Repo.preload(:registered_agent)

    %{workspace: workspace, agent: agent, event: event}
  end

  describe "blocklist evaluation" do
    test "hit returns violation", %{event: event, workspace: workspace} do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :blocklist,
          action: :block,
          config: %{
            "list_type" => "blocklist",
            "field" => "source_ip",
            "values" => ["192.168.1.1", "10.0.0.1"]
          }
        })

      event_with_ip = %{event | source_ip: "192.168.1.1"}

      assert {:violation, details} = ListMatch.evaluate(event_with_ip, rule)
      assert details.list_type == "blocklist"
    end

    test "miss passes", %{event: event, workspace: workspace} do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :blocklist,
          action: :block,
          config: %{
            "list_type" => "blocklist",
            "field" => "source_ip",
            "values" => ["192.168.1.1"]
          }
        })

      event_with_ip = %{event | source_ip: "10.0.0.99"}

      assert {:ok, :passed} = ListMatch.evaluate(event_with_ip, rule)
    end

    test "empty values list means nothing blocked", %{event: event, workspace: workspace} do
      # Create valid rule then modify config in-memory to test empty-values edge case
      # (changeset correctly rejects empty values, but engine must handle it gracefully)
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :blocklist,
          action: :block,
          config: %{
            "list_type" => "blocklist",
            "field" => "source_ip",
            "values" => ["placeholder"]
          }
        })

      empty_values_rule = %{rule | config: Map.put(rule.config, "values", [])}
      event_with_ip = %{event | source_ip: "anything"}

      assert {:ok, :passed} = ListMatch.evaluate(event_with_ip, empty_values_rule)
    end

    test "nil field value for blocklist passes", %{event: event, workspace: workspace} do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :blocklist,
          action: :block,
          config: %{
            "list_type" => "blocklist",
            "field" => "source_ip",
            "values" => ["10.0.0.1"]
          }
        })

      # source_ip is nil by default
      assert event.source_ip == nil
      assert {:ok, :passed} = ListMatch.evaluate(event, rule)
    end

    test "case-insensitive matching", %{event: event, workspace: workspace} do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :blocklist,
          action: :block,
          config: %{
            "list_type" => "blocklist",
            "field" => "agent_name",
            "values" => ["TEST-BOT"]
          }
        })

      # Agent name is "test-bot" (lowercase), blocklist has "TEST-BOT" (uppercase)
      assert {:violation, _details} = ListMatch.evaluate(event, rule)
    end

    test "values with whitespace are trimmed", %{event: event, workspace: workspace} do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :blocklist,
          action: :block,
          config: %{
            "list_type" => "blocklist",
            "field" => "agent_name",
            "values" => ["  test-bot  "]
          }
        })

      assert {:violation, _details} = ListMatch.evaluate(event, rule)
    end
  end

  describe "allowlist evaluation" do
    test "value in list passes", %{event: event, workspace: workspace} do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :allowlist,
          action: :block,
          config: %{
            "list_type" => "allowlist",
            "field" => "agent_name",
            "values" => ["test-bot", "approved-bot"]
          }
        })

      assert {:ok, :passed} = ListMatch.evaluate(event, rule)
    end

    test "value NOT in list returns violation", %{event: event, workspace: workspace} do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :allowlist,
          action: :block,
          config: %{
            "list_type" => "allowlist",
            "field" => "agent_name",
            "values" => ["approved-bot-only"]
          }
        })

      assert {:violation, details} = ListMatch.evaluate(event, rule)
      assert details.list_type == "allowlist"
    end

    test "empty values list for allowlist means everything blocked", %{
      event: event,
      workspace: workspace
    } do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :allowlist,
          action: :block,
          config: %{
            "list_type" => "allowlist",
            "field" => "agent_name",
            "values" => []
          }
        })

      assert {:violation, _details} = ListMatch.evaluate(event, rule)
    end

    test "nil field value for allowlist fails", %{event: event, workspace: workspace} do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :allowlist,
          action: :block,
          config: %{
            "list_type" => "allowlist",
            "field" => "source_ip",
            "values" => ["10.0.0.1"]
          }
        })

      assert event.source_ip == nil
      assert {:violation, _details} = ListMatch.evaluate(event, rule)
    end
  end

  describe "field access security" do
    test "disallowed field returns safe default", %{event: event, workspace: workspace} do
      rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :blocklist,
          action: :block,
          config: %{
            "list_type" => "blocklist",
            "field" => "api_key_hash",
            "values" => ["something"]
          }
        })

      # Should not access api_key_hash field
      assert {:ok, :passed} = ListMatch.evaluate(event, rule)
    end
  end
end
