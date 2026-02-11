defmodule SwarmshieldWeb.DeliberationShowLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures
  import Swarmshield.GhostProtocolFixtures

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "analyst_#{System.unique_integer([:positive])}"})

    permission = permission_fixture(%{resource: "deliberations", action: "view"})
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

  defp create_full_session(%{workspace: workspace}) do
    gp_config = ghost_protocol_config_fixture(%{workspace_id: workspace.id, crypto_shred: true})

    workflow =
      workflow_fixture(%{
        workspace_id: workspace.id,
        ghost_protocol_config_id: gp_config.id
      })

    session =
      analysis_session_fixture(%{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        status: :deliberating,
        trigger: :automatic
      })

    definition =
      agent_definition_fixture(%{
        workspace_id: workspace.id,
        name: "SecurityBot"
      })

    instance =
      agent_instance_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        agent_definition_id: definition.id,
        role: "security_analyst",
        vote: :block,
        confidence: 0.92,
        initial_assessment: "Detected prompt injection attempt"
      })

    message =
      deliberation_message_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        agent_instance_id: instance.id,
        message_type: :analysis,
        content: "This event contains suspicious patterns",
        round: 1
      })

    %{
      session: session,
      workflow: workflow,
      gp_config: gp_config,
      definition: definition,
      instance: instance,
      message: message
    }
  end

  describe "mount and display" do
    setup [:create_full_session]

    test "renders session header with status badge", %{conn: conn, session: session} do
      {:ok, view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert has_element?(view, "#session-header")
      assert html =~ "Deliberation Session"
      assert html =~ "Deliberating"
    end

    test "renders session info cards", %{conn: conn, session: session} do
      {:ok, view, _html} = live(conn, ~p"/deliberations/#{session.id}")

      assert has_element?(view, "#session-info")
    end

    test "renders agent panels with definition name and role", %{
      conn: conn,
      session: session
    } do
      {:ok, view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert has_element?(view, "#agent-panels")
      assert html =~ "SecurityBot"
      assert html =~ "security_analyst"
    end

    test "renders agent vote and confidence", %{conn: conn, session: session} do
      {:ok, _view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert html =~ "Vote: block"
      assert html =~ "92.0% confidence"
    end

    test "renders initial assessment", %{conn: conn, session: session} do
      {:ok, _view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert html =~ "Detected prompt injection attempt"
    end
  end

  describe "message timeline" do
    setup [:create_full_session]

    test "renders deliberation messages in timeline", %{conn: conn, session: session} do
      {:ok, view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert has_element?(view, "#message-timeline")
      assert html =~ "This event contains suspicious patterns"
      assert html =~ "Analysis"
      assert html =~ "Round 1"
    end

    test "shows message author name", %{conn: conn, session: session} do
      {:ok, _view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert html =~ "SecurityBot"
    end

    test "auto-escapes message content (no XSS)", %{
      conn: conn,
      workspace: workspace,
      session: session,
      instance: instance
    } do
      deliberation_message_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        agent_instance_id: instance.id,
        message_type: :argument,
        content: "<script>alert('xss')</script>",
        round: 2
      })

      {:ok, _view, html} = live(conn, ~p"/deliberations/#{session.id}")

      refute html =~ "<script>alert('xss')</script>"
      assert html =~ "&lt;script&gt;"
    end
  end

  describe "verdict display" do
    test "renders verdict panel when verdict exists", %{conn: conn, workspace: workspace} do
      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :completed,
          trigger: :automatic
        })

      verdict_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        decision: :block,
        confidence: 0.95,
        reasoning: "Unanimous agreement on blocking",
        consensus_reached: true,
        dissenting_opinions: []
      })

      {:ok, view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert has_element?(view, "#verdict-panel")
      assert html =~ "Block"
      assert html =~ "95.0% confidence"
      assert html =~ "Unanimous agreement on blocking"
      assert html =~ "Consensus Reached"
    end

    test "shows verdict pending when no verdict", %{conn: conn, workspace: workspace} do
      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :analyzing,
          trigger: :automatic
        })

      {:ok, view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert has_element?(view, "#no-verdict")
      assert html =~ "Verdict pending"
    end

    test "renders dissenting opinions", %{conn: conn, workspace: workspace} do
      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :completed,
          trigger: :automatic
        })

      verdict_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        decision: :flag,
        confidence: 0.72,
        reasoning: "Majority voted to flag",
        consensus_reached: false,
        dissenting_opinions: [
          %{"agent_name" => "Agent-3", "reasoning" => "Content appears benign"}
        ]
      })

      {:ok, _view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert html =~ "Dissenting Opinions"
      assert html =~ "Agent-3"
      assert html =~ "Content appears benign"
    end
  end

  describe "GhostProtocol visualization" do
    setup [:create_full_session]

    test "shows GhostProtocol badge for ephemeral sessions", %{
      conn: conn,
      session: session
    } do
      {:ok, _view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert html =~ "GhostProtocol"
    end

    test "shows GhostProtocol panel with wipe strategy", %{
      conn: conn,
      session: session
    } do
      {:ok, view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert has_element?(view, "#ghost-protocol-panel")
      assert html =~ "Strategy"
      assert html =~ "immediate"
    end

    test "shows crypto shred indicator", %{conn: conn, session: session} do
      {:ok, _view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert html =~ "Crypto Shred"
    end

    test "does not show GhostProtocol panel for non-ephemeral sessions", %{
      conn: conn,
      workspace: workspace
    } do
      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :completed,
          trigger: :manual
        })

      {:ok, view, _html} = live(conn, ~p"/deliberations/#{session.id}")

      refute has_element?(view, "#ghost-protocol-panel")
    end
  end

  describe "error display" do
    test "shows error panel for failed sessions", %{conn: conn, workspace: workspace} do
      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :pending,
          trigger: :automatic
        })

      # Transition to failed with error message
      {:ok, updated} =
        Swarmshield.Deliberation.update_analysis_session(session, %{
          status: :analyzing
        })

      {:ok, failed} =
        Swarmshield.Deliberation.update_analysis_session(updated, %{
          status: :failed,
          error_message: "LLM API timeout after 30s"
        })

      {:ok, view, html} = live(conn, ~p"/deliberations/#{failed.id}")

      assert has_element?(view, "#session-error")
      assert html =~ "LLM API timeout after 30s"
    end
  end

  describe "security" do
    test "redirects when session not found", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: "/deliberations", flash: %{"error" => _}}}} =
               live(conn, ~p"/deliberations/#{fake_id}")
    end

    test "redirects when session belongs to different workspace", %{conn: conn} do
      other_workspace = workspace_fixture()

      session =
        analysis_session_fixture(%{
          workspace_id: other_workspace.id,
          status: :pending,
          trigger: :automatic
        })

      assert {:error, {:redirect, %{to: "/deliberations", flash: %{"error" => _}}}} =
               live(conn, ~p"/deliberations/#{session.id}")
    end

    test "redirects when user lacks deliberations:view permission", %{conn: conn} do
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

      session =
        analysis_session_fixture(%{
          workspace_id: workspace2.id,
          status: :pending,
          trigger: :automatic
        })

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/deliberations/#{session.id}")
    end
  end

  describe "empty states" do
    test "shows empty message state when no messages exist", %{
      conn: conn,
      workspace: workspace
    } do
      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :analyzing,
          trigger: :automatic
        })

      {:ok, view, html} = live(conn, ~p"/deliberations/#{session.id}")

      assert has_element?(view, "#messages-empty")
      assert html =~ "No messages yet"
    end
  end
end
