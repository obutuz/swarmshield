defmodule Swarmshield.GhostProtocol.WipeEngineTest do
  use Swarmshield.DataCase, async: true

  alias Swarmshield.Accounts.AuditEntry
  alias Swarmshield.Deliberation.{AgentInstance, AnalysisSession, DeliberationMessage, Verdict}
  alias Swarmshield.Gateway.AgentEvent
  alias Swarmshield.GhostProtocol.WipeEngine

  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures
  import Swarmshield.GhostProtocolFixtures
  import Swarmshield.GatewayFixtures

  # ---------------------------------------------------------------------------
  # Shared Setup
  # ---------------------------------------------------------------------------

  defp create_full_session(config_attrs \\ %{}, opts \\ []) do
    workspace = workspace_fixture()

    config =
      ghost_protocol_config_fixture(
        Map.merge(
          %{
            workspace_id: workspace.id,
            wipe_strategy: :immediate,
            wipe_fields: ["deliberation_messages", "initial_assessment"],
            crypto_shred: false
          },
          config_attrs
        )
      )

    workflow =
      workflow_fixture(%{
        workspace_id: workspace.id,
        ghost_protocol_config_id: config.id
      })

    agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

    event =
      agent_event_fixture(%{
        workspace_id: workspace.id,
        content: "Suspicious agent output detected",
        payload: %{"raw_output" => "sensitive data here"}
      })

    policy = consensus_policy_fixture(%{workspace_id: workspace.id})

    session =
      analysis_session_fixture(%{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        agent_event_id: event.id,
        consensus_policy_id: policy.id,
        status: :completed,
        metadata: %{"trigger_reason" => "auto_flagged"}
      })

    # Set input_content_hash directly on the session
    {1, _} =
      from(s in AnalysisSession, where: s.id == ^session.id)
      |> Repo.update_all(set: [input_content_hash: "sha256:abc123def456"])

    session = Repo.get!(AnalysisSession, session.id)

    instance_count = Keyword.get(opts, :instance_count, 2)

    instances =
      for i <- 1..instance_count do
        agent_instance_fixture(%{
          workspace_id: workspace.id,
          analysis_session_id: session.id,
          agent_definition_id: agent_def.id,
          status: :completed,
          initial_assessment: "Agent #{i} assessment: content appears suspicious",
          vote: :flag,
          confidence: 0.85
        })
      end

    messages =
      Enum.flat_map(instances, fn instance ->
        for _j <- 1..2 do
          deliberation_message_fixture(%{
            workspace_id: workspace.id,
            analysis_session_id: session.id,
            agent_instance_id: instance.id,
            content: "Deliberation message content for analysis",
            metadata: %{"round_context" => "initial"}
          })
        end
      end)

    verdict =
      verdict_fixture(%{
        workspace_id: workspace.id,
        analysis_session_id: session.id,
        decision: :flag,
        confidence: 0.9,
        reasoning: "Consensus reached: content flagged for review",
        dissenting_opinions: [%{"agent" => "agent-3", "reason" => "low confidence"}],
        vote_breakdown: %{"flag" => 2, "allow" => 0, "block" => 0},
        recommended_actions: ["manual_review"],
        consensus_reached: true,
        consensus_strategy_used: "majority"
      })

    %{
      workspace: workspace,
      config: config,
      workflow: workflow,
      agent_def: agent_def,
      event: event,
      policy: policy,
      session: session,
      instances: instances,
      messages: messages,
      verdict: verdict
    }
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  # Sentinel value used for NOT NULL columns that have been wiped
  @redacted "[REDACTED]"

  describe "execute_wipe/1 - field wiping" do
    test "wipes specified fields on deliberation_messages and agent_instances" do
      %{session: session, messages: messages, instances: instances} = create_full_session()

      assert {:ok, :wipe_completed, _summary} = WipeEngine.execute_wipe(session.id)

      # Deliberation message content should be redacted (NOT NULL column)
      for msg <- messages do
        reloaded = Repo.get!(DeliberationMessage, msg.id)
        assert reloaded.content == @redacted, "deliberation message content should be wiped"
      end

      # Agent instance initial_assessment should be NULL (nullable column)
      for inst <- instances do
        reloaded = Repo.get!(AgentInstance, inst.id)
        assert is_nil(reloaded.initial_assessment), "initial_assessment should be wiped"
      end
    end

    test "unspecified fields remain intact" do
      %{session: session, instances: instances, messages: messages} = create_full_session()

      assert {:ok, :wipe_completed, _summary} = WipeEngine.execute_wipe(session.id)

      # Agent instance vote, confidence, role should survive
      for inst <- instances do
        reloaded = Repo.get!(AgentInstance, inst.id)
        assert reloaded.vote == :flag
        assert reloaded.confidence == 0.85
        assert reloaded.role == "security_analyst"
        assert reloaded.status == :completed
      end

      # Deliberation message metadata, round, message_type should survive
      for msg <- messages do
        reloaded = Repo.get!(DeliberationMessage, msg.id)
        assert reloaded.message_type == :analysis
        assert reloaded.round == 1
        assert reloaded.tokens_used == 150
      end
    end
  end

  describe "execute_wipe/1 - verdict preservation" do
    test "verdict survives wipe with all fields present" do
      %{session: session, verdict: verdict} = create_full_session()

      assert {:ok, :wipe_completed, _summary} = WipeEngine.execute_wipe(session.id)

      reloaded = Repo.get!(Verdict, verdict.id)
      assert reloaded.decision == :flag
      assert reloaded.confidence == 0.9
      assert reloaded.reasoning == "Consensus reached: content flagged for review"

      assert reloaded.dissenting_opinions == [
               %{"agent" => "agent-3", "reason" => "low confidence"}
             ]

      assert reloaded.vote_breakdown == %{"flag" => 2, "allow" => 0, "block" => 0}
      assert reloaded.recommended_actions == ["manual_review"]
      assert reloaded.consensus_reached == true
      assert reloaded.consensus_strategy_used == "majority"
    end
  end

  describe "execute_wipe/1 - crypto shred" do
    test "crypto_shred scenario - fields are destroyed after wipe" do
      %{session: session, messages: messages, instances: instances} =
        create_full_session(%{crypto_shred: true})

      assert {:ok, :wipe_completed, summary} = WipeEngine.execute_wipe(session.id)
      assert summary.crypto_shred_used == true

      # After the full transaction (shred + wipe), NOT NULL fields get redacted
      for msg <- messages do
        reloaded = Repo.get!(DeliberationMessage, msg.id)
        assert reloaded.content == @redacted
      end

      # Nullable fields get NULL
      for inst <- instances do
        reloaded = Repo.get!(AgentInstance, inst.id)
        assert is_nil(reloaded.initial_assessment)
      end
    end
  end

  describe "execute_wipe/1 - non-ephemeral session" do
    test "returns :no_ghost_protocol when workflow has no ghost config" do
      workspace = workspace_fixture()
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      event = agent_event_fixture(%{workspace_id: workspace.id})
      policy = consensus_policy_fixture(%{workspace_id: workspace.id})

      session =
        analysis_session_fixture(%{
          workspace_id: workspace.id,
          workflow_id: workflow.id,
          agent_event_id: event.id,
          consensus_policy_id: policy.id,
          status: :completed
        })

      assert {:error, :no_ghost_protocol} = WipeEngine.execute_wipe(session.id)
    end
  end

  describe "execute_wipe/1 - input_content_hash preservation" do
    test "input_content_hash is preserved after wipe" do
      %{session: session} = create_full_session()

      assert session.input_content_hash == "sha256:abc123def456"

      assert {:ok, :wipe_completed, _summary} = WipeEngine.execute_wipe(session.id)

      reloaded = Repo.get!(AnalysisSession, session.id)
      assert reloaded.input_content_hash == "sha256:abc123def456"
    end
  end

  describe "execute_wipe/1 - agent termination" do
    test "sets terminated_at on all agent_instances" do
      %{session: session, instances: instances} = create_full_session()

      # Confirm terminated_at is nil before wipe
      for inst <- instances do
        reloaded = Repo.get!(AgentInstance, inst.id)
        assert is_nil(reloaded.terminated_at)
      end

      assert {:ok, :wipe_completed, summary} = WipeEngine.execute_wipe(session.id)
      assert summary.agents_terminated == 2

      for inst <- instances do
        reloaded = Repo.get!(AgentInstance, inst.id)
        assert not is_nil(reloaded.terminated_at), "terminated_at should be set"
      end
    end
  end

  describe "execute_wipe/1 - audit entry creation" do
    test "creates audit entry with wipe details" do
      %{session: session, workspace: workspace} = create_full_session()

      assert {:ok, :wipe_completed, _summary} = WipeEngine.execute_wipe(session.id)

      audit =
        from(a in AuditEntry,
          where:
            a.workspace_id == ^workspace.id and
              a.action == "ghost_protocol.wipe_executed" and
              a.resource_id == ^session.id,
          limit: 1
        )
        |> Repo.one()

      assert not is_nil(audit)
      assert audit.resource_type == "analysis_session"
      assert audit.metadata["fields_wiped"] == ["deliberation_messages", "initial_assessment"]
      assert audit.metadata["crypto_shred_used"] == false
      assert audit.metadata["agents_terminated"] == 2
      assert audit.metadata["wipe_strategy"] == "immediate"
    end
  end

  describe "execute_wipe/1 - idempotency" do
    test "second wipe call on same session returns :already_wiped" do
      %{session: session} = create_full_session()

      assert {:ok, :wipe_completed, _summary} = WipeEngine.execute_wipe(session.id)
      assert {:ok, :already_wiped} = WipeEngine.execute_wipe(session.id)
    end
  end

  describe "execute_wipe/1 - PubSub broadcasts" do
    test "broadcasts wipe_started and wipe_completed on PubSub" do
      %{session: session, workspace: workspace} = create_full_session()

      # Subscribe to both session and workspace topics
      Phoenix.PubSub.subscribe(
        Swarmshield.PubSub,
        "ghost_protocol:session:#{session.id}"
      )

      Phoenix.PubSub.subscribe(
        Swarmshield.PubSub,
        "ghost_protocol:#{workspace.id}"
      )

      session_id = session.id

      assert {:ok, :wipe_completed, _summary} = WipeEngine.execute_wipe(session.id)

      # Session-scoped broadcasts
      assert_received {:wipe_started, ^session_id}
      assert_received {:wipe_completed, ^session_id}

      # Workspace-scoped broadcasts (for dashboard)
      # The workspace topic receives both messages too
      assert_received {:wipe_started, ^session_id}
      assert_received {:wipe_completed, ^session_id}
    end
  end

  describe "execute_wipe/1 - empty wipe_fields" do
    test "wipe with empty wipe_fields still sets terminated_at" do
      %{session: session, instances: instances, messages: messages} =
        create_full_session(%{wipe_fields: []})

      assert {:ok, :wipe_completed, summary} = WipeEngine.execute_wipe(session.id)
      assert summary.fields_wiped == []
      assert summary.agents_terminated == 2

      # terminated_at should be set
      for inst <- instances do
        reloaded = Repo.get!(AgentInstance, inst.id)
        assert not is_nil(reloaded.terminated_at)
      end

      # But content should remain since no fields were specified
      for msg <- messages do
        reloaded = Repo.get!(DeliberationMessage, msg.id)
        assert not is_nil(reloaded.content)
      end
    end
  end

  describe "execute_wipe/1 - all allowed fields" do
    test "all allowed wipe fields work together" do
      all_fields = ~w(input_content deliberation_messages metadata initial_assessment payload)

      %{session: session, instances: instances, messages: messages, event: event} =
        create_full_session(%{wipe_fields: all_fields})

      assert {:ok, :wipe_completed, summary} = WipeEngine.execute_wipe(session.id)
      assert Enum.sort(summary.fields_wiped) == Enum.sort(all_fields)

      # deliberation_messages content wiped (NOT NULL column -> redacted)
      for msg <- messages do
        reloaded = Repo.get!(DeliberationMessage, msg.id)
        assert reloaded.content == @redacted
      end

      # initial_assessment wiped (nullable -> NULL)
      for inst <- instances do
        reloaded = Repo.get!(AgentInstance, inst.id)
        assert is_nil(reloaded.initial_assessment)
      end

      # metadata wiped on session and deliberation_messages (nullable -> NULL)
      reloaded_session = Repo.get!(AnalysisSession, session.id)
      assert is_nil(reloaded_session.metadata)

      for msg <- messages do
        reloaded = Repo.get!(DeliberationMessage, msg.id)
        assert is_nil(reloaded.metadata)
      end

      # input_content wiped on agent_event (NOT NULL column -> redacted)
      reloaded_event = Repo.get!(AgentEvent, event.id)
      assert reloaded_event.content == @redacted

      # payload wiped on agent_event (nullable -> NULL)
      assert is_nil(reloaded_event.payload)

      # Verdict still intact
      verdict =
        from(v in Verdict, where: v.analysis_session_id == ^session.id)
        |> Repo.one!()

      assert verdict.decision == :flag
      assert verdict.reasoning == "Consensus reached: content flagged for review"
    end
  end

  describe "execute_wipe/1 - session not found" do
    test "returns error for non-existent session" do
      assert {:error, :session_not_found} =
               WipeEngine.execute_wipe(Ecto.UUID.generate())
    end
  end

  describe "execute_wipe/1 - delayed/scheduled strategies" do
    test "delayed strategy returns schedule info instead of executing" do
      %{session: session} =
        create_full_session(%{wipe_strategy: :delayed, wipe_delay_seconds: 60})

      assert {:ok, :scheduled, schedule_info} = WipeEngine.execute_wipe(session.id)
      assert schedule_info.wipe_strategy == :delayed
      assert schedule_info.wipe_delay_seconds == 60
      assert schedule_info.session_id == session.id
      assert %DateTime{} = schedule_info.scheduled_at
    end

    test "scheduled strategy returns schedule info" do
      %{session: session} =
        create_full_session(%{wipe_strategy: :scheduled, wipe_delay_seconds: 3600})

      assert {:ok, :scheduled, schedule_info} = WipeEngine.execute_wipe(session.id)
      assert schedule_info.wipe_strategy == :scheduled
      assert schedule_info.wipe_delay_seconds == 3600
    end
  end

  describe "execute_wipe/1 - disabled config" do
    test "returns error when config is disabled" do
      %{session: session, config: config} = create_full_session(%{enabled: true})

      # Disable the config after creation
      config
      |> Ecto.Changeset.change(%{enabled: false})
      |> Repo.update!()

      assert {:error, :config_disabled} = WipeEngine.execute_wipe(session.id)
    end
  end
end
