defmodule SwarmshieldWeb.GhostProtocolSessionLiveTest do
  use SwarmshieldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures
  import Swarmshield.GhostProtocolFixtures

  setup %{conn: conn} do
    user = user_fixture()
    workspace = workspace_fixture()
    role = role_fixture(%{name: "gps_role_#{System.unique_integer([:positive])}"})

    permission = permission_fixture(%{resource: "ghost_protocol", action: "view"})
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

  defp create_ephemeral_session(workspace) do
    gp_config =
      ghost_protocol_config_fixture(%{
        workspace_id: workspace.id,
        crypto_shred: true,
        wipe_strategy: :immediate,
        max_session_duration_seconds: 600,
        auto_terminate_on_expiry: true,
        wipe_fields: ["input_content", "deliberation_messages"]
      })

    workflow =
      workflow_fixture(%{
        workspace_id: workspace.id,
        ghost_protocol_config_id: gp_config.id
      })

    agent_def =
      agent_definition_fixture(%{
        workspace_id: workspace.id,
        name: "Security Analyst #{System.unique_integer([:positive])}"
      })

    session =
      analysis_session_fixture(%{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        status: :analyzing,
        trigger: :automatic
      })

    instance =
      agent_instance_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        agent_definition_id: agent_def.id,
        status: :running,
        role: "security_analyst"
      })

    %{
      config: gp_config,
      workflow: workflow,
      session: session,
      agent_def: agent_def,
      instance: instance
    }
  end

  describe "mount and display" do
    test "renders ephemeral session page with header and lifecycle", %{
      conn: conn,
      workspace: workspace
    } do
      %{session: session} = create_ephemeral_session(workspace)

      {:ok, view, html} = live(conn, ~p"/ghost-protocol/#{session.id}")

      assert html =~ "Ephemeral Session"
      assert has_element?(view, "#gp-session-header")
      assert has_element?(view, "#lifecycle-timeline")
      assert has_element?(view, "#session-info")
      assert has_element?(view, "#agent-cards")
      assert has_element?(view, "#config-details")
    end

    test "displays session ID prefix in header", %{conn: conn, workspace: workspace} do
      %{session: session} = create_ephemeral_session(workspace)

      {:ok, _view, html} = live(conn, ~p"/ghost-protocol/#{session.id}")

      assert html =~ String.slice(session.id, 0, 8)
    end

    test "displays lifecycle phases correctly", %{conn: conn, workspace: workspace} do
      %{session: session} = create_ephemeral_session(workspace)

      {:ok, _view, html} = live(conn, ~p"/ghost-protocol/#{session.id}")

      assert html =~ "Spawn"
      assert html =~ "Analyze"
      assert html =~ "Debate"
      assert html =~ "Vote"
      assert html =~ "Verdict"
      assert html =~ "Wiped"
    end
  end

  describe "agent status cards" do
    test "shows agent instance with definition name and role", %{
      conn: conn,
      workspace: workspace
    } do
      %{session: session, agent_def: agent_def} = create_ephemeral_session(workspace)

      {:ok, _view, html} = live(conn, ~p"/ghost-protocol/#{session.id}")

      assert html =~ agent_def.name
      assert html =~ "security_analyst"
    end

    test "shows terminated agent with red styling", %{conn: conn, workspace: workspace} do
      %{session: session, instance: instance} = create_ephemeral_session(workspace)

      # Terminate the agent
      {:ok, _} =
        Swarmshield.Deliberation.update_agent_instance(instance, %{
          status: :completed,
          terminated_at: DateTime.utc_now()
        })

      {:ok, _view, html} = live(conn, ~p"/ghost-protocol/#{session.id}")

      assert html =~ "Terminated"
    end

    test "shows agent vote and confidence when present", %{conn: conn, workspace: workspace} do
      %{session: session, instance: instance} = create_ephemeral_session(workspace)

      {:ok, _} =
        Swarmshield.Deliberation.update_agent_instance(instance, %{
          vote: :block,
          confidence: 0.923
        })

      {:ok, _view, html} = live(conn, ~p"/ghost-protocol/#{session.id}")

      assert html =~ "92.3%"
    end

    test "shows empty state when no agents spawned", %{conn: conn, workspace: workspace} do
      gp_config = ghost_protocol_config_fixture(%{workspace_id: workspace.id})

      workflow =
        workflow_fixture(%{
          workspace_id: workspace.id,
          ghost_protocol_config_id: gp_config.id
        })

      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          status: :pending,
          trigger: :automatic
        })

      {:ok, _view, html} = live(conn, ~p"/ghost-protocol/#{session.id}")

      assert html =~ "No agents spawned yet"
    end
  end

  describe "verdict display" do
    test "shows surviving verdict with decision badge and confidence", %{
      conn: conn,
      workspace: workspace
    } do
      %{session: session} = create_ephemeral_session(workspace)

      _verdict =
        verdict_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id,
          decision: :block,
          confidence: 0.95,
          reasoning: "Multiple threat indicators detected",
          consensus_reached: true
        })

      {:ok, view, html} = live(conn, ~p"/ghost-protocol/#{session.id}")

      assert has_element?(view, "#surviving-verdict")
      assert html =~ "Surviving Artifact: Verdict"
      assert html =~ "Block"
      assert html =~ "95.0%"
      assert html =~ "Multiple threat indicators detected"
      assert html =~ "Consensus"
    end

    test "shows pending verdict state when no verdict exists", %{
      conn: conn,
      workspace: workspace
    } do
      %{session: session} = create_ephemeral_session(workspace)

      {:ok, view, html} = live(conn, ~p"/ghost-protocol/#{session.id}")

      assert has_element?(view, "#no-verdict")
      assert html =~ "Verdict pending"
    end
  end

  describe "config details" do
    test "shows ghost_protocol_config settings", %{conn: conn, workspace: workspace} do
      %{session: session, config: config} = create_ephemeral_session(workspace)

      {:ok, _view, html} = live(conn, ~p"/ghost-protocol/#{session.id}")

      assert html =~ config.name
      assert html =~ "immediate"
      assert html =~ "600s"
      assert html =~ "Enabled"
      assert html =~ "input_content"
      assert html =~ "deliberation_messages"
    end
  end

  describe "error display" do
    test "shows error message when session has error", %{conn: conn, workspace: workspace} do
      %{session: session} = create_ephemeral_session(workspace)

      # Session is already :analyzing from fixture, transition to failed
      {:ok, _failed} =
        Swarmshield.Deliberation.update_analysis_session(session, %{
          status: :failed,
          error_message: "LLM budget exceeded"
        })

      {:ok, view, html} = live(conn, ~p"/ghost-protocol/#{session.id}")

      assert has_element?(view, "#session-error")
      assert html =~ "LLM budget exceeded"
    end
  end

  describe "non-ephemeral redirect" do
    test "redirects non-ephemeral session to /deliberations/:id", %{
      conn: conn,
      workspace: workspace
    } do
      # Session without ghost_protocol_config = not ephemeral
      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          status: :analyzing,
          trigger: :automatic
        })

      assert {:error, {:redirect, %{to: path}}} =
               live(conn, ~p"/ghost-protocol/#{session.id}")

      assert path =~ "/deliberations/#{session.id}"
    end
  end

  describe "security" do
    test "redirects when user lacks ghost_protocol:view permission", %{conn: conn} do
      user2 = user_fixture()
      workspace2 = workspace_fixture()
      role2 = role_fixture(%{name: "noperm_gps_#{System.unique_integer([:positive])}"})

      user_workspace_role_fixture(user2, workspace2, role2)

      token2 = Swarmshield.Accounts.generate_user_session_token(user2)

      conn2 =
        conn
        |> recycle()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:user_token, token2)
        |> Plug.Conn.put_session(:current_workspace_id, workspace2.id)

      gp_config = ghost_protocol_config_fixture(%{workspace_id: workspace2.id})

      workflow =
        workflow_fixture(%{
          workspace_id: workspace2.id,
          ghost_protocol_config_id: gp_config.id
        })

      session =
        analysis_session_fixture(%{
          workspace_id: workspace2.id,
          workflow_id: workflow.id,
          status: :analyzing,
          trigger: :automatic
        })

      assert {:error, {:redirect, %{to: "/select-workspace"}}} =
               live(conn2, ~p"/ghost-protocol/#{session.id}")
    end

    test "returns not found for session in different workspace", %{
      conn: conn,
      workspace: _workspace
    } do
      other_workspace = workspace_fixture()
      other_gp = ghost_protocol_config_fixture(%{workspace_id: other_workspace.id})

      other_workflow =
        workflow_fixture(%{
          workspace_id: other_workspace.id,
          ghost_protocol_config_id: other_gp.id
        })

      other_session =
        analysis_session_fixture(%{
          workspace_id: other_workspace.id,
          workflow_id: other_workflow.id,
          status: :analyzing,
          trigger: :automatic
        })

      assert {:error, {:redirect, %{to: "/ghost-protocol"}}} =
               live(conn, ~p"/ghost-protocol/#{other_session.id}")
    end

    test "returns not found for nonexistent session ID", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: "/ghost-protocol"}}} =
               live(conn, ~p"/ghost-protocol/#{fake_id}")
    end
  end
end
