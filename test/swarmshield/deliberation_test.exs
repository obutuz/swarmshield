defmodule Swarmshield.DeliberationTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Deliberation
  alias Swarmshield.Deliberation.{AgentInstance, AnalysisSession, DeliberationMessage, Verdict}

  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures
  import Swarmshield.GatewayFixtures

  setup do
    workspace = workspace_fixture()
    %{workspace: workspace}
  end

  # ---------------------------------------------------------------------------
  # AnalysisSession
  # ---------------------------------------------------------------------------

  describe "list_analysis_sessions/2" do
    test "returns paginated sessions for workspace with verdict preloaded", %{
      workspace: workspace
    } do
      session = analysis_session_fixture(%{workspace_id: workspace.id})

      {sessions, total_count} = Deliberation.list_analysis_sessions(workspace.id)

      assert total_count == 1
      [found] = sessions
      assert found.id == session.id
      assert Ecto.assoc_loaded?(found.verdict)
    end

    test "filters by status", %{workspace: workspace} do
      analysis_session_fixture(%{workspace_id: workspace.id, status: :pending})
      analysis_session_fixture(%{workspace_id: workspace.id, status: :completed})

      {sessions, total_count} =
        Deliberation.list_analysis_sessions(workspace.id, status: :pending)

      assert total_count == 1
      [found] = sessions
      assert found.status == :pending
    end

    test "filters by trigger", %{workspace: workspace} do
      analysis_session_fixture(%{workspace_id: workspace.id, trigger: :automatic})
      analysis_session_fixture(%{workspace_id: workspace.id, trigger: :manual})

      {sessions, total_count} =
        Deliberation.list_analysis_sessions(workspace.id, trigger: :manual)

      assert total_count == 1
      [found] = sessions
      assert found.trigger == :manual
    end

    test "filters by date range", %{workspace: workspace} do
      analysis_session_fixture(%{workspace_id: workspace.id})

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {_sessions, total_count} = Deliberation.list_analysis_sessions(workspace.id, from: future)
      assert total_count == 0
    end

    test "paginates results", %{workspace: workspace} do
      for _i <- 1..5, do: analysis_session_fixture(%{workspace_id: workspace.id})

      {sessions, total_count} =
        Deliberation.list_analysis_sessions(workspace.id, page: 1, page_size: 2)

      assert total_count == 5
      assert length(sessions) == 2
    end

    test "does not return sessions from other workspaces", %{workspace: workspace} do
      other_workspace = workspace_fixture()
      analysis_session_fixture(%{workspace_id: other_workspace.id})

      {sessions, total_count} = Deliberation.list_analysis_sessions(workspace.id)

      assert total_count == 0
      assert sessions == []
    end
  end

  describe "get_analysis_session!/1" do
    test "returns session with preloaded associations", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})

      instance =
        agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id
        })

      _message =
        deliberation_message_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id,
          agent_instance_id: instance.id
        })

      found = Deliberation.get_analysis_session!(session.id)

      assert found.id == session.id
      assert Ecto.assoc_loaded?(found.agent_instances)
      assert Ecto.assoc_loaded?(found.verdict)
      assert length(found.agent_instances) == 1
      [loaded_instance] = found.agent_instances
      assert Ecto.assoc_loaded?(loaded_instance.deliberation_messages)
      assert length(loaded_instance.deliberation_messages) == 1
    end

    test "raises for missing id" do
      assert_raise Ecto.NoResultsError, fn ->
        Deliberation.get_analysis_session!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_analysis_session_for_workspace!/2" do
    test "returns session scoped to workspace", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})
      found = Deliberation.get_analysis_session_for_workspace!(session.id, workspace.id)
      assert found.id == session.id
    end

    test "raises when session belongs to different workspace", %{workspace: workspace} do
      other_workspace = workspace_fixture()
      session = analysis_session_fixture(%{workspace_id: other_workspace.id})

      assert_raise Ecto.NoResultsError, fn ->
        Deliberation.get_analysis_session_for_workspace!(session.id, workspace.id)
      end
    end
  end

  describe "create_analysis_session/1" do
    test "creates session with valid attrs", %{workspace: workspace} do
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      policy = consensus_policy_fixture(%{workspace_id: workspace.id})
      event = agent_event_fixture(%{workspace_id: workspace.id})

      assert {:ok, %AnalysisSession{} = session} =
               Deliberation.create_analysis_session(%{
                 status: :pending,
                 trigger: :automatic,
                 workspace_id: workspace.id,
                 workflow_id: workflow.id,
                 consensus_policy_id: policy.id,
                 agent_event_id: event.id,
                 metadata: %{"source" => "test"}
               })

      assert session.status == :pending
      assert session.trigger == :automatic
      assert session.workspace_id == workspace.id
    end

    test "returns error with invalid attrs" do
      assert {:error, %Ecto.Changeset{}} =
               Deliberation.create_analysis_session(%{status: :pending})
    end

    test "broadcasts PubSub on creation", %{workspace: workspace} do
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberations:#{workspace.id}")

      workflow = workflow_fixture(%{workspace_id: workspace.id})
      policy = consensus_policy_fixture(%{workspace_id: workspace.id})
      event = agent_event_fixture(%{workspace_id: workspace.id})

      {:ok, session} =
        Deliberation.create_analysis_session(%{
          status: :pending,
          trigger: :automatic,
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          consensus_policy_id: policy.id,
          agent_event_id: event.id
        })

      session_id = session.id
      assert_receive {:session_created, ^session_id, :pending}
    end
  end

  describe "update_analysis_session/2" do
    test "updates with valid status transition", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id, status: :pending})
      now = DateTime.utc_now(:second)

      assert {:ok, %AnalysisSession{} = updated} =
               Deliberation.update_analysis_session(session, %{
                 status: :analyzing,
                 started_at: now
               })

      assert updated.status == :analyzing
      assert updated.started_at == now
    end

    test "rejects invalid status transition", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id, status: :completed})

      assert {:error, "cannot transition from completed to analyzing"} =
               Deliberation.update_analysis_session(session, %{status: :analyzing})
    end

    test "allows transition to failed from any active state", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id, status: :analyzing})

      assert {:ok, updated} =
               Deliberation.update_analysis_session(session, %{
                 status: :failed,
                 error_message: "LLM timeout"
               })

      assert updated.status == :failed
    end

    test "broadcasts PubSub on status change", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id, status: :pending})
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberation:#{session.id}")

      {:ok, _updated} =
        Deliberation.update_analysis_session(session, %{status: :analyzing})

      assert_receive {:session_updated, _, :analyzing}
    end
  end

  # ---------------------------------------------------------------------------
  # AgentInstance
  # ---------------------------------------------------------------------------

  describe "list_agent_instances/1" do
    test "returns instances for session with agent_definition preloaded", %{
      workspace: workspace
    } do
      session = analysis_session_fixture(%{workspace_id: workspace.id})

      instance =
        agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id
        })

      instances = Deliberation.list_agent_instances(session.id)

      assert length(instances) == 1
      [found] = instances
      assert found.id == instance.id
      assert Ecto.assoc_loaded?(found.agent_definition)
    end

    test "returns empty list for session with no instances", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})
      assert Deliberation.list_agent_instances(session.id) == []
    end
  end

  describe "get_agent_instance!/1" do
    test "returns instance with preloaded associations", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})

      instance =
        agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id
        })

      found = Deliberation.get_agent_instance!(instance.id)
      assert found.id == instance.id
      assert Ecto.assoc_loaded?(found.agent_definition)
      assert Ecto.assoc_loaded?(found.deliberation_messages)
    end
  end

  describe "create_agent_instance/1" do
    test "creates instance with valid attrs", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})
      definition = agent_definition_fixture(%{workspace_id: workspace.id})

      assert {:ok, %AgentInstance{} = instance} =
               Deliberation.create_agent_instance(%{
                 status: :pending,
                 role: "security_analyst",
                 analysis_session_id: session.id,
                 agent_definition_id: definition.id
               })

      assert instance.role == "security_analyst"
      assert instance.analysis_session_id == session.id
    end
  end

  describe "update_agent_instance/2" do
    test "updates instance with assessment and vote", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})

      instance =
        agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id
        })

      assert {:ok, updated} =
               Deliberation.update_agent_instance(instance, %{
                 status: :completed,
                 initial_assessment: "No threats detected.",
                 vote: :allow,
                 confidence: 0.92,
                 tokens_used: 1500,
                 cost_cents: 3
               })

      assert updated.vote == :allow
      assert updated.confidence == 0.92
      assert updated.tokens_used == 1500
    end
  end

  # ---------------------------------------------------------------------------
  # DeliberationMessage
  # ---------------------------------------------------------------------------

  describe "create_deliberation_message/1" do
    test "creates message with valid attrs", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})

      instance =
        agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id
        })

      assert {:ok, %DeliberationMessage{} = message} =
               Deliberation.create_deliberation_message(%{
                 message_type: :analysis,
                 content: "Initial analysis complete.",
                 round: 1,
                 tokens_used: 200,
                 analysis_session_id: session.id,
                 agent_instance_id: instance.id
               })

      assert message.message_type == :analysis
      assert message.round == 1
    end
  end

  describe "list_messages_by_session/1" do
    test "returns messages ordered by round ASC, inserted_at ASC", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})

      instance =
        agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id
        })

      {:ok, msg1} =
        Deliberation.create_deliberation_message(%{
          message_type: :analysis,
          content: "Round 1 analysis",
          round: 1,
          analysis_session_id: session.id,
          agent_instance_id: instance.id
        })

      {:ok, msg2} =
        Deliberation.create_deliberation_message(%{
          message_type: :argument,
          content: "Round 2 argument",
          round: 2,
          analysis_session_id: session.id,
          agent_instance_id: instance.id
        })

      messages = Deliberation.list_messages_by_session(session.id)

      assert length(messages) == 2
      assert hd(messages).id == msg1.id
      assert List.last(messages).id == msg2.id
      assert Ecto.assoc_loaded?(hd(messages).agent_instance)
    end

    test "returns empty list for session with no messages", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})
      assert Deliberation.list_messages_by_session(session.id) == []
    end
  end

  describe "list_messages_by_instance/1" do
    test "returns messages for specific instance", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})

      instance1 =
        agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id
        })

      instance2 =
        agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id
        })

      {:ok, _msg1} =
        Deliberation.create_deliberation_message(%{
          message_type: :analysis,
          content: "From instance 1",
          round: 1,
          analysis_session_id: session.id,
          agent_instance_id: instance1.id
        })

      {:ok, _msg2} =
        Deliberation.create_deliberation_message(%{
          message_type: :analysis,
          content: "From instance 2",
          round: 1,
          analysis_session_id: session.id,
          agent_instance_id: instance2.id
        })

      messages = Deliberation.list_messages_by_instance(instance1.id)
      assert length(messages) == 1
      assert hd(messages).content == "From instance 1"
    end
  end

  # ---------------------------------------------------------------------------
  # Verdict
  # ---------------------------------------------------------------------------

  describe "create_verdict/1" do
    test "creates verdict with valid attrs", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})

      assert {:ok, %Verdict{} = verdict} =
               Deliberation.create_verdict(%{
                 decision: :allow,
                 confidence: 0.85,
                 reasoning: "All agents agreed the content is safe.",
                 vote_breakdown: %{"allow" => 3, "flag" => 0, "block" => 0},
                 consensus_reached: true,
                 consensus_strategy_used: "majority",
                 analysis_session_id: session.id
               })

      assert verdict.decision == :allow
      assert verdict.consensus_reached == true
    end

    test "prevents duplicate verdict for same session", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})
      _existing = verdict_fixture(%{workspace_id: workspace.id, analysis_session_id: session.id})

      assert {:error, %Ecto.Changeset{}} =
               Deliberation.create_verdict(%{
                 decision: :block,
                 confidence: 0.9,
                 reasoning: "Duplicate attempt.",
                 analysis_session_id: session.id
               })
    end

    test "broadcasts PubSub on verdict creation", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberation:#{session.id}")

      {:ok, verdict} =
        Deliberation.create_verdict(%{
          decision: :flag,
          confidence: 0.75,
          reasoning: "Potential issue detected.",
          analysis_session_id: session.id
        })

      verdict_id = verdict.id
      assert_receive {:verdict_reached, ^verdict_id, :flag}
    end
  end

  describe "get_verdict_by_session/1" do
    test "returns verdict for session", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})
      verdict = verdict_fixture(%{workspace_id: workspace.id, analysis_session_id: session.id})

      found = Deliberation.get_verdict_by_session(session.id)
      assert found.id == verdict.id
    end

    test "returns nil for session without verdict", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})
      assert Deliberation.get_verdict_by_session(session.id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Aggregates
  # ---------------------------------------------------------------------------

  describe "session_token_totals/1" do
    test "computes totals via database SUM", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})

      instance1 =
        agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id
        })

      instance2 =
        agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id
        })

      Deliberation.update_agent_instance(instance1, %{tokens_used: 1000, cost_cents: 2})
      Deliberation.update_agent_instance(instance2, %{tokens_used: 500, cost_cents: 1})

      totals = Deliberation.session_token_totals(session.id)
      assert totals.total_tokens == 1500
      assert totals.total_cost_cents == 3
    end

    test "returns zero for session with no instances", %{workspace: workspace} do
      session = analysis_session_fixture(%{workspace_id: workspace.id})
      totals = Deliberation.session_token_totals(session.id)
      assert totals.total_tokens == 0
      assert totals.total_cost_cents == 0
    end
  end
end
