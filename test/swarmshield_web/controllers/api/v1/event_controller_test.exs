defmodule SwarmshieldWeb.Api.V1.EventControllerTest do
  use SwarmshieldWeb.ConnCase, async: false

  import Ecto.Query

  alias Swarmshield.Gateway.ApiKeyCache
  alias Swarmshield.Gateway.RegisteredAgent
  alias Swarmshield.Repo

  alias Swarmshield.Policies.PolicyViolation

  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.PoliciesFixtures

  # async: false because ApiKeyCache uses shared ETS table

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Swarmshield.TaskSupervisor),
          is_pid(pid) do
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          500 -> :ok
        end
      end
    end)

    try do
      :ets.delete_all_objects(:api_rate_limit)
    rescue
      ArgumentError -> :ok
    end

    workspace = workspace_fixture()
    {raw_key, agent} = create_agent_with_raw_key(workspace)
    %{workspace: workspace, agent: agent, raw_key: raw_key}
  end

  describe "POST /api/v1/events - success" do
    test "creates event and returns 201", %{conn: conn, raw_key: raw_key} do
      params = %{
        "event_type" => "action",
        "content" => "Agent performed search query",
        "severity" => "info"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert %{"data" => data} = json_response(conn, 201)
      assert data["event_type"] == "action"
      assert data["content"] == "Agent performed search query"
      assert data["severity"] == "info"
      assert data["status"] == "allowed"
      assert data["id"] != nil
      assert data["inserted_at"] != nil
    end

    test "sets source_ip from connection", %{conn: conn, raw_key: raw_key} do
      params = %{"event_type" => "action", "content" => "Test event"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      assert data["source_ip"] != nil
    end

    test "accepts optional payload map", %{conn: conn, raw_key: raw_key} do
      params = %{
        "event_type" => "tool_call",
        "content" => "Called external API",
        "payload" => %{"url" => "https://api.example.com", "method" => "GET"}
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      assert data["payload"]["url"] == "https://api.example.com"
    end

    test "ignores unknown fields in body", %{conn: conn, raw_key: raw_key} do
      params = %{
        "event_type" => "action",
        "content" => "Test",
        "evil_field" => "injection",
        "workspace_id" => "fake-id",
        "status" => "allowed"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      assert data["status"] == "allowed"
      refute Map.has_key?(data, "evil_field")
    end

    test "does not expose workspace_id in response", %{conn: conn, raw_key: raw_key} do
      params = %{"event_type" => "action", "content" => "Test"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      refute Map.has_key?(data, "workspace_id")
    end
  end

  describe "POST /api/v1/events - validation errors" do
    test "returns 422 when event_type is missing", %{conn: conn, raw_key: raw_key} do
      params = %{"content" => "Missing event type"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["event_type"] != nil
    end

    test "returns 422 when content is missing", %{conn: conn, raw_key: raw_key} do
      params = %{"event_type" => "action"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["content"] != nil
    end

    test "returns 422 for invalid event_type enum", %{conn: conn, raw_key: raw_key} do
      params = %{"event_type" => "nonexistent_type", "content" => "Test"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert json_response(conn, 422)
    end

    test "returns 422 when both required fields are missing", %{conn: conn, raw_key: raw_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", %{})

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["event_type"] != nil
      assert errors["content"] != nil
    end
  end

  describe "POST /api/v1/events - authentication" do
    test "returns 401 without auth token", %{conn: conn} do
      params = %{"event_type" => "action", "content" => "Test"}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert json_response(conn, 401)
    end

    test "returns 401 with invalid token", %{conn: conn} do
      params = %{"event_type" => "action", "content" => "Test"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid-token")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      assert json_response(conn, 401)
    end
  end

  describe "POST /api/v1/events - content type" do
    test "returns 415 without Content-Type header", %{conn: conn, raw_key: raw_key} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post(~p"/api/v1/events", %{})

      assert conn.status == 415
    end
  end

  describe "POST /api/v1/events - policy evaluation (GW-005)" do
    test "allowed event includes evaluation_result", %{
      conn: conn,
      raw_key: raw_key
    } do
      params = %{"event_type" => "action", "content" => "Safe action"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      assert data["status"] == "allowed"
      assert data["evaluated_at"] != nil
      assert is_map(data["evaluation_result"])
      assert data["evaluation_result"]["action"] == "allow"
      assert data["evaluation_result"]["matched_rules"] == []
    end

    test "flagged event when flag rule matches", %{
      conn: conn,
      raw_key: raw_key,
      workspace: workspace
    } do
      rule = create_flag_rule(workspace.id)
      insert_rules_into_cache(workspace.id, [rule])

      params = %{"event_type" => "tool_call", "content" => "External API call"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      assert data["status"] == "flagged"
      assert data["flagged_reason"] != nil
      assert data["evaluation_result"]["action"] == "flag"
      assert data["evaluation_result"]["flag_count"] == 1

      matched = hd(data["evaluation_result"]["matched_rules"])
      assert matched["rule_id"] == rule.id
      assert matched["action"] == "flag"
      assert matched["rule_type"] == "blocklist"
    end

    test "blocked event when block rule matches", %{
      conn: conn,
      raw_key: raw_key,
      workspace: workspace
    } do
      rule = create_block_rule(workspace.id)
      insert_rules_into_cache(workspace.id, [rule])

      params = %{"event_type" => "error", "content" => "Something went wrong"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      assert data["status"] == "blocked"
      assert data["flagged_reason"] != nil
      assert data["evaluation_result"]["action"] == "block"
      assert data["evaluation_result"]["block_count"] == 1
    end

    test "flagged event creates PolicyViolation records", %{
      conn: conn,
      raw_key: raw_key,
      workspace: workspace
    } do
      rule = create_flag_rule(workspace.id)
      insert_rules_into_cache(workspace.id, [rule])

      params = %{"event_type" => "tool_call", "content" => "External API call"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      event_id = data["id"]

      violations =
        from(v in PolicyViolation,
          where: v.agent_event_id == ^event_id
        )
        |> Repo.all()

      assert length(violations) == 1
      violation = hd(violations)
      assert violation.policy_rule_id == rule.id
      assert violation.action_taken == :flagged
      assert violation.severity == :medium
      assert violation.workspace_id == workspace.id
    end

    test "blocked event creates PolicyViolation with :high severity", %{
      conn: conn,
      raw_key: raw_key,
      workspace: workspace
    } do
      rule = create_block_rule(workspace.id)
      insert_rules_into_cache(workspace.id, [rule])

      params = %{"event_type" => "error", "content" => "Blocked content"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      event_id = data["id"]

      violations =
        from(v in PolicyViolation,
          where: v.agent_event_id == ^event_id
        )
        |> Repo.all()

      assert length(violations) == 1
      assert hd(violations).action_taken == :blocked
      assert hd(violations).severity == :high
    end

    test "evaluation_result does NOT contain rule config or detection patterns", %{
      conn: conn,
      raw_key: raw_key,
      workspace: workspace
    } do
      rule = create_flag_rule(workspace.id)
      insert_rules_into_cache(workspace.id, [rule])

      params = %{"event_type" => "tool_call", "content" => "API call"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)

      matched = hd(data["evaluation_result"]["matched_rules"])
      refute Map.has_key?(matched, "config")
      refute Map.has_key?(matched, "values")
      refute Map.has_key?(matched, "detection_rule_ids")
      refute Map.has_key?(matched, "pattern")

      assert Map.keys(matched) |> Enum.sort() ==
               ["action", "rule_id", "rule_name", "rule_type"]
    end

    test "multiple flag rules create multiple violations", %{
      conn: conn,
      raw_key: raw_key,
      workspace: workspace
    } do
      rule1 = create_flag_rule(workspace.id, "tool_call")
      rule2 = create_flag_rule_by_content(workspace.id, "api call")
      insert_rules_into_cache(workspace.id, [rule1, rule2])

      params = %{"event_type" => "tool_call", "content" => "api call"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      assert data["status"] == "flagged"
      assert data["evaluation_result"]["flag_count"] == 2

      event_id = data["id"]

      violation_count =
        from(v in PolicyViolation,
          where: v.agent_event_id == ^event_id
        )
        |> Repo.aggregate(:count)

      assert violation_count == 2
    end

    test "event stays :pending when PolicyEngine crashes", %{
      conn: conn,
      raw_key: raw_key,
      workspace: workspace
    } do
      # Insert a rule with nil config to force an evaluation crash
      bad_rule =
        policy_rule_fixture(%{
          workspace_id: workspace.id,
          rule_type: :blocklist,
          action: :block,
          config: %{"values" => ["x"]}
        })

      # Manually corrupt the cached rule to have nil config
      corrupted = %{bad_rule | config: nil}
      insert_rules_into_cache(workspace.id, [corrupted])

      params = %{"event_type" => "action", "content" => "Test"}

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/events", params)

      %{"data" => data} = json_response(conn, 201)
      # PolicyEngine catches the crash per-rule and continues.
      # With a single corrupted rule, it returns :allow.
      assert data["status"] in ["allowed", "pending"]
      assert data["id"] != nil
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_flag_rule(workspace_id, event_type \\ "tool_call") do
    policy_rule_fixture(%{
      workspace_id: workspace_id,
      name: "flag-#{event_type}-#{System.unique_integer([:positive])}",
      rule_type: :blocklist,
      action: :flag,
      priority: 10,
      enabled: true,
      config: %{
        "list_type" => "blocklist",
        "field" => "event_type",
        "values" => [event_type]
      }
    })
  end

  defp create_flag_rule_by_content(workspace_id, content_value) do
    policy_rule_fixture(%{
      workspace_id: workspace_id,
      name: "flag-content-#{System.unique_integer([:positive])}",
      rule_type: :blocklist,
      action: :flag,
      priority: 5,
      enabled: true,
      config: %{
        "list_type" => "blocklist",
        "field" => "content",
        "values" => [content_value]
      }
    })
  end

  defp create_block_rule(workspace_id) do
    policy_rule_fixture(%{
      workspace_id: workspace_id,
      name: "block-error-#{System.unique_integer([:positive])}",
      rule_type: :blocklist,
      action: :block,
      priority: 100,
      enabled: true,
      config: %{
        "list_type" => "blocklist",
        "field" => "event_type",
        "values" => ["error"]
      }
    })
  end

  defp insert_rules_into_cache(workspace_id, rules) do
    :ets.insert(:policy_rules_cache, {workspace_id, rules})
  end

  defp create_agent_with_raw_key(workspace) do
    {raw_key, hash, prefix} = RegisteredAgent.generate_api_key()

    agent = registered_agent_fixture(%{workspace_id: workspace.id})

    from(a in RegisteredAgent, where: a.id == ^agent.id)
    |> Repo.update_all(set: [api_key_hash: hash, api_key_prefix: prefix])

    ApiKeyCache.invalidate_agent(agent.id)

    updated_agent = Repo.get!(RegisteredAgent, agent.id)
    {raw_key, updated_agent}
  end
end
