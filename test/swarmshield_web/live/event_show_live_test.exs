defmodule SwarmshieldWeb.EventShowLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.DeliberationFixtures

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "analyst_#{System.unique_integer([:positive])}"})

    permission = permission_fixture(%{resource: "events", action: "view"})
    role_permission_fixture(role, permission)

    user_workspace_role_fixture(user, workspace, role)

    token = Swarmshield.Accounts.generate_user_session_token(user)

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_token, token)
      |> Plug.Conn.put_session(:current_workspace_id, workspace.id)

    %{conn: conn, user: user, workspace: workspace}
  end

  describe "mount and display" do
    test "renders event detail page", %{conn: conn, workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, status: :active})

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Agent executed file_read on /etc/passwd",
          event_type: :action,
          status: :flagged,
          severity: :warning
        })

      {:ok, view, html} = live(conn, ~p"/events/#{event.id}")

      assert html =~ "Event Details"
      assert html =~ "Agent executed file_read on /etc/passwd"
      assert has_element?(view, "#event-header")
      assert has_element?(view, "#event-data")
    end

    test "shows payload as formatted JSON", %{conn: conn, workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, status: :active})

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Tool call with payload",
          event_type: :tool_call,
          payload: %{"tool" => "file_read", "path" => "/etc/shadow"}
        })

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}")

      assert has_element?(view, "#event-payload")
      html = render(view)
      assert html =~ "file_read"
      assert html =~ "/etc/shadow"
    end

    test "shows evaluation result and matched rules", %{conn: conn, workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, status: :active})

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Suspicious output detected",
          event_type: :output,
          status: :blocked,
          evaluation_result: %{
            "action" => "block",
            "evaluated_count" => 5,
            "block_count" => 1,
            "flag_count" => 0,
            "matched_rules" => [
              %{
                "rule_id" => Ecto.UUID.generate(),
                "rule_name" => "Credential Exfiltration",
                "action" => "block",
                "rule_type" => "pattern_match"
              }
            ]
          },
          flagged_reason: "block: matched 1 rule(s) - Credential Exfiltration"
        })

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}")

      assert has_element?(view, "#evaluation-result")
      html = render(view)
      assert html =~ "Credential Exfiltration"
      assert html =~ "block"
      assert html =~ "pattern_match"
    end
  end

  describe "linked deliberation session" do
    test "shows linked session with verdict in main column", %{
      conn: conn,
      workspace: workspace
    } do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, status: :active})

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Flagged event with deliberation",
          event_type: :action,
          status: :flagged
        })

      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          agent_event_id: event.id,
          status: :completed,
          trigger: :automatic
        })

      verdict_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        decision: :block,
        confidence: 0.92,
        reasoning: "Multiple agents agree this is malicious",
        consensus_reached: true,
        consensus_strategy_used: "supermajority"
      })

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}")

      # Sidebar still shows compact deliberation card
      assert has_element?(view, "#linked-session")

      # Verdict summary now in main column
      assert has_element?(view, "#verdict-summary")

      html = render(view)
      assert html =~ "Final Verdict"
      assert html =~ "block"
      assert html =~ "92.0%"
      assert html =~ "Consensus"
      assert html =~ "Multiple agents agree this is malicious"
      assert html =~ "Supermajority"
      assert html =~ "View Full Deliberation"
    end

    test "shows vote breakdown bar when votes present", %{conn: conn, workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, status: :active})

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Event with vote breakdown",
          event_type: :action,
          status: :flagged
        })

      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          agent_event_id: event.id,
          status: :completed,
          trigger: :automatic
        })

      verdict_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        decision: :block,
        confidence: 0.99,
        reasoning: "Unanimous block decision",
        consensus_reached: true,
        vote_breakdown: %{"block" => 3, "flag" => 0, "allow" => 0}
      })

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}")

      assert has_element?(view, "#vote-breakdown")
      html = render(view)
      assert html =~ "Vote Breakdown"
      assert html =~ "block"
    end

    test "shows agent votes grid when agents have voted", %{conn: conn, workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, status: :active})

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Event with agent votes",
          event_type: :action,
          status: :flagged
        })

      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          agent_event_id: event.id,
          status: :completed,
          trigger: :automatic
        })

      # Create agent definitions and instances with votes
      def1 =
        agent_definition_fixture(%{
          workspace_id: workspace.id,
          name: "PII Guardian",
          role: "pii_detector"
        })

      def2 =
        agent_definition_fixture(%{
          workspace_id: workspace.id,
          name: "Compliance Officer",
          role: "compliance_analyst"
        })

      agent_instance_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        agent_definition_id: def1.id,
        status: :completed,
        vote: :block,
        confidence: 0.99,
        role: "pii_detector"
      })

      agent_instance_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        agent_definition_id: def2.id,
        status: :completed,
        vote: :block,
        confidence: 0.95,
        role: "compliance_analyst"
      })

      verdict_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        decision: :block,
        confidence: 0.97,
        reasoning: "Agents agreed on blocking",
        consensus_reached: true,
        vote_breakdown: %{"block" => 2, "flag" => 0, "allow" => 0}
      })

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}")

      assert has_element?(view, "#agent-votes")
      html = render(view)
      assert html =~ "Agent Votes"
      assert html =~ "PII Guardian"
      assert html =~ "Compliance Officer"
      assert html =~ "99.0%"
      assert html =~ "95.0%"
    end

    test "does not show verdict summary when no verdict exists", %{
      conn: conn,
      workspace: workspace
    } do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, status: :active})

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Event with session but no verdict",
          event_type: :action,
          status: :flagged
        })

      # Session without a verdict (still in progress)
      _session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          agent_event_id: event.id,
          status: :pending,
          trigger: :automatic
        })

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}")

      # Sidebar shows session info
      assert has_element?(view, "#linked-session")
      # No verdict summary card
      refute has_element?(view, "#verdict-summary")
    end

    test "shows no-session card when no deliberation linked", %{
      conn: conn,
      workspace: workspace
    } do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, status: :active})

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Simple allowed event",
          event_type: :action,
          status: :allowed
        })

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}")

      assert has_element?(view, "#no-session")
      refute has_element?(view, "#linked-session")
      refute has_element?(view, "#verdict-summary")
    end
  end

  describe "enhanced violations" do
    test "shows richer violation details with badges", %{conn: conn, workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, status: :active})

      event =
        agent_event_fixture(%{
          workspace_id: workspace.id,
          registered_agent_id: agent.id,
          content: "Event with violations",
          event_type: :action,
          status: :blocked
        })

      # Create a violation directly via Repo to ensure it's linked
      alias Swarmshield.Policies.PolicyViolation
      alias Swarmshield.Repo

      policy_rule =
        Swarmshield.PoliciesFixtures.policy_rule_fixture(%{workspace_id: workspace.id})

      {:ok, _violation} =
        %PolicyViolation{
          workspace_id: workspace.id,
          agent_event_id: event.id,
          policy_rule_id: policy_rule.id
        }
        |> PolicyViolation.changeset(%{
          action_taken: :blocked,
          severity: :critical,
          details: %{
            "rule_name" => "Data Exfiltration Detection",
            "rule_type" => "pattern_match",
            "matched_pattern" => "password|secret"
          }
        })
        |> Repo.insert()

      {:ok, view, _html} = live(conn, ~p"/events/#{event.id}")

      assert has_element?(view, "#violations-section")
      html = render(view)
      assert html =~ "Data Exfiltration Detection"
      assert html =~ "critical"
      assert html =~ "blocked"
      assert html =~ "pattern_match"
      # Extra detail key should be displayed
      assert html =~ "Matched Pattern"
      assert html =~ "password|secret"
    end
  end

  describe "security" do
    test "redirects to events list when event not found", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: "/events"}}} = live(conn, ~p"/events/#{fake_id}")
    end

    test "redirects for event from wrong workspace", %{conn: conn} do
      # Create event in a different workspace
      other_workspace = workspace_fixture()
      agent = registered_agent_fixture(%{workspace_id: other_workspace.id, status: :active})

      event =
        agent_event_fixture(%{
          workspace_id: other_workspace.id,
          registered_agent_id: agent.id,
          content: "Event in other workspace"
        })

      # Should redirect - event doesn't belong to user's workspace
      assert {:error, {:redirect, %{to: "/events"}}} = live(conn, ~p"/events/#{event.id}")
    end

    test "redirects when user lacks events:view permission", %{conn: conn} do
      user2 = user_fixture()
      workspace2 = workspace_fixture()
      role2 = role_fixture(%{name: "noperm_#{System.unique_integer([:positive])}"})

      user_workspace_role_fixture(user2, workspace2, role2)

      token2 = Swarmshield.Accounts.generate_user_session_token(user2)

      conn2 =
        conn
        |> recycle()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, token2)
        |> Plug.Conn.put_session(:current_workspace_id, workspace2.id)

      fake_id = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/events/#{fake_id}")
    end
  end

  describe "status badges" do
    test "renders correct status badge for each status", %{conn: conn, workspace: workspace} do
      agent = registered_agent_fixture(%{workspace_id: workspace.id, status: :active})

      for status <- [:allowed, :flagged, :blocked, :pending] do
        event =
          agent_event_fixture(%{
            workspace_id: workspace.id,
            registered_agent_id: agent.id,
            content: "Event with status #{status}",
            event_type: :action,
            status: status
          })

        {:ok, _view, html} = live(conn, ~p"/events/#{event.id}")

        expected_label = status |> to_string() |> String.capitalize()
        assert html =~ expected_label
      end
    end
  end
end
