defmodule Swarmshield.Deliberation.SessionTest do
  use Swarmshield.DataCase, async: false

  alias Swarmshield.Deliberation
  alias Swarmshield.Deliberation.Session
  alias Swarmshield.LLM

  import Swarmshield.AccountsFixtures
  import Swarmshield.DeliberationFixtures
  import Swarmshield.GatewayFixtures
  import Swarmshield.GhostProtocolFixtures

  setup do
    workspace = workspace_fixture()
    %{workspace: workspace}
  end

  # Mock backend that returns successful LLM responses
  defp success_backend(vote \\ "FLAG", confidence \\ "0.8") do
    fn _model, _messages, _opts ->
      {:ok,
       %{
         text: "Analysis indicates potential risk. VOTE: #{vote} CONFIDENCE: #{confidence}",
         usage: %{input_tokens: 100, output_tokens: 50, total_cost: 0.02},
         finish_reason: :stop,
         error: nil
       }}
    end
  end

  defp setup_workflow(workspace, opts \\ []) do
    ghost_config =
      if Keyword.get(opts, :ephemeral, false) do
        ghost_protocol_config_fixture(%{
          workspace_id: workspace.id,
          wipe_strategy: :immediate,
          wipe_fields: ["deliberation_messages", "initial_assessment"],
          max_session_duration_seconds: 300,
          crypto_shred: false
        })
      end

    workflow =
      workflow_fixture(%{
        workspace_id: workspace.id,
        ghost_protocol_config_id: ghost_config && ghost_config.id
      })

    agent_def = agent_definition_fixture(%{workspace_id: workspace.id})

    workflow_step_fixture(%{
      workspace_id: workspace.id,
      workflow_id: workflow.id,
      agent_definition_id: agent_def.id,
      position: 1
    })

    policy = consensus_policy_fixture(%{workspace_id: workspace.id})

    event =
      agent_event_fixture(%{
        workspace_id: workspace.id,
        content: "Test content for deliberation"
      })

    # Reload workflow with preloads
    workflow = Swarmshield.Workflows.get_workflow!(workflow.id)

    %{
      workflow: workflow,
      policy: policy,
      event: event,
      agent_def: agent_def,
      ghost_config: ghost_config
    }
  end

  # ---------------------------------------------------------------------------
  # Session Lifecycle (DELIB-008)
  # ---------------------------------------------------------------------------

  describe "start_session/3" do
    test "starts a session and runs full pipeline", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event} = setup_workflow(workspace)

      opts = [
        backend: success_backend(),
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 10_000
      ]

      assert {:ok, pid} = Session.start_session(event, workflow, opts)
      assert is_pid(pid)

      # Wait for GenServer to complete (it stops with :normal)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      # Verify session was created and completed
      sessions =
        Deliberation.list_analysis_sessions(workspace.id)
        |> elem(0)

      assert [_ | _] = sessions
      session = Enum.find(sessions, &(&1.agent_event_id == event.id))
      assert session != nil
      assert session.status in [:completed, :failed]
    end

    test "rejects workspace mismatch", %{workspace: workspace} do
      %{workflow: workflow, event: _event} = setup_workflow(workspace)
      other_workspace = workspace_fixture()

      other_event =
        agent_event_fixture(%{workspace_id: other_workspace.id, content: "other content"})

      assert {:error, :workspace_mismatch} = Session.start_session(other_event, workflow)
    end

    test "creates session with pending status initially", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event} = setup_workflow(workspace)

      # Use a backend that hangs so we can check initial state
      hanging_backend = fn _model, _messages, _opts ->
        Process.sleep(5_000)

        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      end

      opts = [backend: hanging_backend, consensus_policy_id: policy.id, deliberation_rounds: 0]
      {:ok, pid} = Session.start_session(event, workflow, opts)

      # The session exists in the DB
      {sessions, _} = Deliberation.list_analysis_sessions(workspace.id)
      assert [_ | _] = sessions

      Process.exit(pid, :kill)
    end

    test "ephemeral session sets expires_at and input_content_hash", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event} =
        setup_workflow(workspace, ephemeral: true)

      opts = [
        backend: success_backend(),
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 10_000
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      {sessions, _} = Deliberation.list_analysis_sessions(workspace.id)
      session = Enum.find(sessions, &(&1.agent_event_id == event.id))

      assert session.input_content_hash != nil
      assert session.expires_at != nil
    end

    test "non-ephemeral session has nil expires_at and nil input_content_hash", %{
      workspace: workspace
    } do
      %{workflow: workflow, policy: policy, event: event} =
        setup_workflow(workspace, ephemeral: false)

      opts = [
        backend: success_backend(),
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 10_000
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      {sessions, _} = Deliberation.list_analysis_sessions(workspace.id)
      session = Enum.find(sessions, &(&1.agent_event_id == event.id))

      assert session.expires_at == nil
      assert session.input_content_hash == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Analysis Phase (DELIB-009)
  # ---------------------------------------------------------------------------

  describe "analysis phase" do
    test "creates agent instances and analysis messages", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event} = setup_workflow(workspace)

      opts = [
        backend: success_backend("BLOCK", "0.9"),
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 10_000
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      {sessions, _} = Deliberation.list_analysis_sessions(workspace.id)
      session = Enum.find(sessions, &(&1.agent_event_id == event.id))

      agents = Deliberation.list_agent_instances(session.id)
      assert [agent | _] = agents
      assert agent.status == :completed
      assert agent.vote != nil
      assert agent.initial_assessment != nil

      messages = Deliberation.list_messages_by_session(session.id)
      analysis_messages = Enum.filter(messages, &(&1.message_type == :analysis))
      assert [_ | _] = analysis_messages
    end

    test "handles agent failure gracefully with partial results", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event, agent_def: agent_def} =
        setup_workflow(workspace)

      # Add a second step so we have 2 agents
      workflow_step_fixture(%{
        workspace_id: workspace.id,
        workflow_id: workflow.id,
        agent_definition_id: agent_def.id,
        position: 2
      })

      workflow = Swarmshield.Workflows.get_workflow!(workflow.id)

      call_count = :counters.new(1, [:atomics])

      mixed_backend = fn _model, _messages, _opts ->
        count = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        if count == 0 do
          {:ok,
           %{
             text: "VOTE: FLAG CONFIDENCE: 0.7",
             usage: %{input_tokens: 50, output_tokens: 25, total_cost: 0.01},
             finish_reason: :stop,
             error: nil
           }}
        else
          {:error, :timeout}
        end
      end

      opts = [
        backend: mixed_backend,
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 10_000
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      {sessions, _} = Deliberation.list_analysis_sessions(workspace.id)
      session = Enum.find(sessions, &(&1.agent_event_id == event.id))

      # Session should still complete with partial results
      assert session.status in [:completed, :failed]
    end

    test "workflow with 0 steps completes analysis immediately", %{workspace: workspace} do
      # Create workflow with no steps
      workflow = workflow_fixture(%{workspace_id: workspace.id})
      workflow = Swarmshield.Workflows.get_workflow!(workflow.id)
      policy = consensus_policy_fixture(%{workspace_id: workspace.id})
      event = agent_event_fixture(%{workspace_id: workspace.id, content: "test"})

      opts = [
        backend: success_backend(),
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 10_000
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    end

    test "all agents timeout marks session as failed", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event} = setup_workflow(workspace)

      timeout_backend = fn _model, _messages, _opts ->
        Process.sleep(5_000)

        {:ok,
         %{
           text: "ok",
           usage: %{input_tokens: 0, output_tokens: 0, total_cost: 0.0},
           finish_reason: :stop,
           error: nil
         }}
      end

      opts = [
        backend: timeout_backend,
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 100
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      {sessions, _} = Deliberation.list_analysis_sessions(workspace.id)
      session = Enum.find(sessions, &(&1.agent_event_id == event.id))
      assert session.status == :failed
    end
  end

  # ---------------------------------------------------------------------------
  # Deliberation Phase (DELIB-010)
  # ---------------------------------------------------------------------------

  describe "deliberation phase" do
    test "runs configured deliberation rounds", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event} = setup_workflow(workspace)

      opts = [
        backend: success_backend("FLAG", "0.8"),
        consensus_policy_id: policy.id,
        deliberation_rounds: 1,
        analysis_timeout: 10_000
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 15_000

      {sessions, _} = Deliberation.list_analysis_sessions(workspace.id)
      session = Enum.find(sessions, &(&1.agent_event_id == event.id))

      messages = Deliberation.list_messages_by_session(session.id)

      # Should have analysis messages (round 1) and argument messages (round 2)
      analysis_msgs = Enum.filter(messages, &(&1.message_type == :analysis))
      argument_msgs = Enum.filter(messages, &(&1.message_type == :argument))

      assert [_ | _] = analysis_msgs
      assert [_ | _] = argument_msgs
    end

    test "0 deliberation rounds skips deliberation phase", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event} = setup_workflow(workspace)

      opts = [
        backend: success_backend(),
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 10_000
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      {sessions, _} = Deliberation.list_analysis_sessions(workspace.id)
      session = Enum.find(sessions, &(&1.agent_event_id == event.id))

      messages = Deliberation.list_messages_by_session(session.id)
      argument_msgs = Enum.filter(messages, &(&1.message_type == :argument))
      assert argument_msgs == []
    end
  end

  # ---------------------------------------------------------------------------
  # Verdict Phase (DELIB-012)
  # ---------------------------------------------------------------------------

  describe "verdict phase" do
    test "creates verdict with consensus", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event} = setup_workflow(workspace)

      opts = [
        backend: success_backend("BLOCK", "0.9"),
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 10_000
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      {sessions, _} = Deliberation.list_analysis_sessions(workspace.id)
      session = Enum.find(sessions, &(&1.agent_event_id == event.id))

      verdict = Deliberation.get_verdict_by_session(session.id)
      assert verdict != nil
      assert verdict.decision in [:allow, :flag, :block, :escalate]
      assert verdict.confidence > 0.0
      assert verdict.reasoning != nil
      assert is_map(verdict.vote_breakdown)
    end

    test "session is marked completed after verdict", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event} = setup_workflow(workspace)

      opts = [
        backend: success_backend(),
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 10_000
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      {sessions, _} = Deliberation.list_analysis_sessions(workspace.id)
      session = Enum.find(sessions, &(&1.agent_event_id == event.id))

      assert session.status == :completed
      assert session.completed_at != nil
      assert session.total_tokens_used >= 0
      assert session.total_cost_cents >= 0
    end

    test "records token totals on session", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event} = setup_workflow(workspace)

      opts = [
        backend: success_backend(),
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 10_000
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      {sessions, _} = Deliberation.list_analysis_sessions(workspace.id)
      session = Enum.find(sessions, &(&1.agent_event_id == event.id))

      assert session.total_tokens_used > 0
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub (DELIB-008)
  # ---------------------------------------------------------------------------

  describe "PubSub broadcasts" do
    test "broadcasts session lifecycle events", %{workspace: workspace} do
      %{workflow: workflow, policy: policy, event: event} = setup_workflow(workspace)

      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberations:#{workspace.id}")

      opts = [
        backend: success_backend(),
        consensus_policy_id: policy.id,
        deliberation_rounds: 0,
        analysis_timeout: 10_000
      ]

      {:ok, pid} = Session.start_session(event, workflow, opts)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000

      # Should receive session created broadcast
      assert_receive {:session_created, _session_id, :pending}, 5_000
    end
  end

  # ---------------------------------------------------------------------------
  # build_context/2
  # ---------------------------------------------------------------------------

  describe "build_context" do
    test "build_context creates proper ReqLLM context" do
      context = LLM.Client.build_context("system prompt", "user content")
      assert [_, _] = ReqLLM.Context.to_list(context)
    end
  end
end
