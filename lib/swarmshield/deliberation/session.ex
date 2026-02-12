defmodule Swarmshield.Deliberation.Session do
  @moduledoc """
  GenServer managing the lifecycle of a single deliberation session.

  Started under DynamicSupervisor, orchestrates:
  analysis -> deliberation -> voting -> verdict -> (if ephemeral) wipe

  For ephemeral workflows (ghost_protocol_config_id present), uses
  restart: :temporary so BEAM GC cleans process memory after termination.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Swarmshield.Accounts
  alias Swarmshield.Deliberation
  alias Swarmshield.Deliberation.{Consensus, PromptRenderer}
  alias Swarmshield.GhostProtocol.WipeEngine
  alias Swarmshield.LLM.Client, as: LLMClient
  alias Swarmshield.Workflows

  @registry Swarmshield.Deliberation.SessionRegistry
  @default_deliberation_rounds 2
  @default_analysis_timeout 30_000
  @vote_allowlist ~w(allow flag block)a

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_session(map(), map(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_session(event, workflow, opts \\ []) do
    with :ok <- validate_same_workspace(event, workflow) do
      case existing_session(event.id) do
        {:ok, pid} -> {:ok, pid}
        :none -> start_new_session(event, workflow, opts)
      end
    end
  end

  defp start_new_session(event, workflow, opts) do
    init_arg = %{event: event, workflow: workflow, opts: opts}

    case DynamicSupervisor.start_child(
           Swarmshield.Deliberation.SessionSupervisor,
           {__MODULE__, init_arg}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  def start_link(init_arg) do
    event = init_arg.event
    name = via_tuple(event.id)
    GenServer.start_link(__MODULE__, init_arg, name: name)
  end

  def get_session_state(event_id) do
    case Registry.lookup(@registry, event_id) do
      [{pid, _}] -> GenServer.call(pid, :get_state)
      [] -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(%{event: event, workflow: workflow, opts: opts}) do
    workflow = load_full_workflow(workflow.id)
    ghost_config = load_ghost_config(workflow)
    consensus_policy = load_consensus_policy(workflow, opts)

    now = DateTime.utc_now(:second)
    ephemeral? = ghost_config != nil

    expires_at = compute_expires_at(ghost_config, now)
    input_content_hash = compute_content_hash(ephemeral?, event.content)

    {:ok, session} =
      create_session_record(event, workflow, consensus_policy, expires_at, input_content_hash)

    state = %{
      session_id: session.id,
      session: session,
      event: event,
      workflow: workflow,
      ghost_config: ghost_config,
      consensus_policy: consensus_policy,
      agents: [],
      phase: :pending,
      ephemeral?: ephemeral?,
      opts: opts
    }

    schedule_expiry(expires_at, ghost_config)

    {:ok, state, {:continue, :start_analysis}}
  end

  @impl true
  def handle_continue(:start_analysis, state) do
    state = run_analysis_phase(state)

    case state.phase do
      :failed ->
        {:stop, :normal, state}

      :analyzing_complete ->
        state = run_deliberation_phase(state)
        state = run_verdict_phase(state)
        maybe_wipe_and_stop(state)
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    reply = %{
      session_id: state.session_id,
      phase: state.phase,
      ephemeral?: state.ephemeral?,
      agent_count: length(state.agents)
    }

    {:reply, {:ok, reply}, state}
  end

  @impl true
  def handle_info(:check_expiry, state) do
    ghost_config = state.ghost_config

    cond do
      ghost_config == nil ->
        {:noreply, state}

      state.phase in [:completed, :failed, :timed_out, :wiping] ->
        {:noreply, state}

      expired?(state.session) and ghost_config.auto_terminate_on_expiry ->
        state = force_terminate_expired(state)
        {:stop, :normal, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:execute_delayed_wipe, session_id}, %{session_id: session_id} = state) do
    execute_wipe(state)
    {:stop, :normal, %{state | phase: :wiping}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Phase 1: Analysis (DELIB-009)
  # ---------------------------------------------------------------------------

  defp run_analysis_phase(state) do
    %{session: session, event: event, workflow: workflow, opts: opts} = state

    {:ok, session} =
      Deliberation.update_analysis_session(session, %{
        status: :analyzing,
        started_at: DateTime.utc_now(:second)
      })

    steps = workflow.workflow_steps || []

    case steps do
      [] ->
        %{state | session: session, phase: :analyzing_complete}

      _ ->
        run_parallel_analysis(steps, session, event, opts, state)
    end
  end

  defp run_parallel_analysis(steps, session, event, opts, state) do
    backend = Keyword.get(opts, :backend)

    tasks =
      Enum.map(steps, fn step ->
        agent_def = step.agent_definition

        {:ok, instance} =
          Deliberation.create_agent_instance(%{
            analysis_session_id: session.id,
            agent_definition_id: agent_def.id,
            status: :running,
            role: agent_def.role,
            started_at: DateTime.utc_now(:second)
          })

        # Extract values BEFORE spawning task (no state copying)
        instance_id = instance.id
        session_id = session.id
        system_prompt = render_system_prompt(agent_def, step)
        user_content = event.content || ""
        model = "anthropic:#{agent_def.model}"
        temperature = agent_def.temperature || 0.3
        max_tokens = agent_def.max_tokens || 4096
        workspace_id = session.workspace_id

        task =
          Task.Supervisor.async_nolink(
            Swarmshield.TaskSupervisor,
            fn ->
              llm_opts =
                [
                  model: model,
                  temperature: temperature,
                  max_tokens: max_tokens,
                  workspace_id: workspace_id
                ]
                |> maybe_add_backend(backend)

              context = LLMClient.build_context(system_prompt, user_content)
              result = LLMClient.chat(context, llm_opts)
              {instance_id, session_id, result}
            end
          )

        {task, instance}
      end)

    timeout = Keyword.get(opts, :analysis_timeout, @default_analysis_timeout)
    task_refs = Enum.map(tasks, fn {task, _instance} -> task end)
    results = Task.yield_many(task_refs, timeout)

    agents =
      tasks
      |> Enum.zip(results)
      |> Enum.map(fn {{_task, instance}, {_task_ref, result}} ->
        process_analysis_result(instance, result, session.id)
      end)

    completed = Enum.filter(agents, &(&1.status == :completed))

    state =
      case completed do
        [] ->
          fail_session(state, session, "All agents timed out or failed during analysis")

        _ ->
          broadcast_phase(session, :analysis_complete, %{agent_count: length(completed)})
          %{state | session: session, agents: agents, phase: :analyzing_complete}
      end

    state
  end

  defp process_analysis_result(instance, result, session_id) do
    case result do
      {:ok, {_instance_id, _session_id, {:ok, chat_result}}} ->
        {vote, confidence} = parse_llm_vote(chat_result.text)

        {:ok, updated} =
          Deliberation.update_agent_instance(instance, %{
            status: :completed,
            completed_at: DateTime.utc_now(:second),
            initial_assessment: chat_result.text,
            vote: vote,
            confidence: confidence,
            tokens_used: chat_result.input_tokens + chat_result.output_tokens,
            cost_cents: chat_result.cost_cents
          })

        Deliberation.create_deliberation_message(%{
          analysis_session_id: session_id,
          agent_instance_id: instance.id,
          message_type: :analysis,
          content: chat_result.text,
          round: 1,
          tokens_used: chat_result.input_tokens + chat_result.output_tokens
        })

        updated

      {:ok, {_instance_id, _session_id, {:error, reason}}} ->
        {:ok, updated} =
          Deliberation.update_agent_instance(instance, %{
            status: :failed,
            completed_at: DateTime.utc_now(:second),
            error_message: inspect(reason)
          })

        updated

      {:exit, reason} ->
        {:ok, updated} =
          Deliberation.update_agent_instance(instance, %{
            status: :failed,
            completed_at: DateTime.utc_now(:second),
            error_message: "Task exited: #{inspect(reason)}"
          })

        updated

      nil ->
        {:ok, updated} =
          Deliberation.update_agent_instance(instance, %{
            status: :timed_out,
            completed_at: DateTime.utc_now(:second),
            error_message: "Analysis timed out"
          })

        updated
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 2: Deliberation (DELIB-010)
  # ---------------------------------------------------------------------------

  defp run_deliberation_phase(state) do
    %{session: session, event: event, opts: opts} = state
    rounds = deliberation_rounds(state.workflow, opts)

    case rounds do
      0 ->
        state

      _ ->
        {:ok, session} =
          Deliberation.update_analysis_session(session, %{status: :deliberating})

        completed_agents = Enum.filter(state.agents, &(&1.status == :completed))
        state = %{state | session: session}

        Enum.reduce(1..rounds, state, fn round, acc_state ->
          run_deliberation_round(acc_state, completed_agents, event, round + 1, opts)
        end)
    end
  end

  defp run_deliberation_round(state, agents, event, round, opts) do
    session = state.session
    backend = Keyword.get(opts, :backend)

    previous_messages = Deliberation.list_messages_by_session(session.id)

    # Window to last 2 rounds of messages to prevent unbounded memory growth.
    # At 20M concurrent users, full history per agent would exhaust memory.
    max_context_messages = length(agents) * 2

    debate_summary =
      previous_messages
      |> Enum.take(-max_context_messages)
      |> Enum.map_join("\n\n", fn msg ->
        role = msg.agent_instance_id
        "[Agent #{String.slice(role || "unknown", 0..7)}] (#{msg.message_type}): #{msg.content}"
      end)

    # Preload all agent instances with definitions in a single query (avoid N+1)
    agent_ids = Enum.map(agents, & &1.id)
    preloaded_agents = Deliberation.list_agent_instances_by_ids(agent_ids)

    tasks =
      Enum.map(preloaded_agents, fn agent ->
        agent_def = agent.agent_definition

        instance_id = agent.id
        session_id = session.id
        system_prompt = build_deliberation_prompt(agent_def)

        user_content =
          "Original event:\n#{event.content}\n\nPrevious discussion:\n#{debate_summary}\n\nProvide your response for round #{round}."

        model = "anthropic:#{agent_def.model}"
        temperature = agent_def.temperature || 0.5
        max_tokens = agent_def.max_tokens || 4096
        workspace_id = session.workspace_id

        task =
          Task.Supervisor.async_nolink(
            Swarmshield.TaskSupervisor,
            fn ->
              llm_opts =
                [
                  model: model,
                  temperature: temperature,
                  max_tokens: max_tokens,
                  workspace_id: workspace_id
                ]
                |> maybe_add_backend(backend)

              context = LLMClient.build_context(system_prompt, user_content)
              result = LLMClient.chat(context, llm_opts)
              {instance_id, session_id, result}
            end
          )

        {task, agent}
      end)

    timeout = Keyword.get(opts, :analysis_timeout, @default_analysis_timeout)
    task_refs = Enum.map(tasks, fn {task, _} -> task end)
    results = Task.yield_many(task_refs, timeout)

    updated_agents =
      tasks
      |> Enum.zip(results)
      |> Enum.map(fn {{_task, agent}, {_task_ref, result}} ->
        process_deliberation_result(agent, result, session.id, round)
      end)

    broadcast_phase(session, :deliberation_round_complete, %{round: round})

    %{state | agents: merge_agents(state.agents, updated_agents)}
  end

  defp process_deliberation_result(agent, result, session_id, round) do
    case result do
      {:ok, {_instance_id, _session_id, {:ok, chat_result}}} ->
        {vote, confidence} = parse_llm_vote(chat_result.text)

        {:ok, updated} =
          Deliberation.update_agent_instance(agent, %{
            vote: vote || agent.vote,
            confidence: confidence || agent.confidence,
            tokens_used:
              (agent.tokens_used || 0) + chat_result.input_tokens + chat_result.output_tokens,
            cost_cents: (agent.cost_cents || 0) + chat_result.cost_cents
          })

        message_type = if round > 2, do: :counter_argument, else: :argument

        Deliberation.create_deliberation_message(%{
          analysis_session_id: session_id,
          agent_instance_id: agent.id,
          message_type: message_type,
          content: chat_result.text,
          round: round,
          tokens_used: chat_result.input_tokens + chat_result.output_tokens
        })

        updated

      _ ->
        agent
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 3: Verdict (DELIB-012)
  # ---------------------------------------------------------------------------

  defp run_verdict_phase(state) do
    %{session: session, consensus_policy: policy} = state

    {:ok, session} =
      Deliberation.update_analysis_session(session, %{status: :voting})

    agents = refresh_agents(session.id)
    votes = build_votes(agents)

    {consensus_result, decision, details} = evaluate_consensus(votes, policy)
    confidence = Consensus.confidence_score(votes)
    dissenting = build_dissenting(agents, decision, consensus_result)
    vote_breakdown = Consensus.vote_breakdown(votes) |> stringify_keys()

    reasoning = build_reasoning(consensus_result, decision, details)

    final_decision =
      case consensus_result do
        :consensus -> decision
        :no_consensus -> :escalate
      end

    {:ok, verdict} =
      Deliberation.create_verdict(%{
        analysis_session_id: session.id,
        decision: final_decision,
        confidence: confidence,
        reasoning: reasoning,
        vote_breakdown: vote_breakdown,
        dissenting_opinions: dissenting,
        consensus_reached: consensus_result == :consensus,
        consensus_strategy_used: to_string(policy.strategy)
      })

    totals = Deliberation.session_token_totals(session.id)

    {:ok, session} =
      Deliberation.update_analysis_session(session, %{
        status: :completed,
        completed_at: DateTime.utc_now(:second),
        total_tokens_used: totals.total_tokens,
        total_cost_cents: totals.total_cost_cents
      })

    update_event_status(state.event, final_decision)
    audit_verdict(session, verdict)
    broadcast_phase(session, :verdict_reached, %{decision: final_decision})

    %{state | session: session, agents: agents, phase: :completed}
  end

  # ---------------------------------------------------------------------------
  # Phase 4: GhostProtocol Wipe (DELIB-013) + Expiry (DELIB-014)
  # ---------------------------------------------------------------------------

  defp maybe_wipe_and_stop(%{ephemeral?: false} = state) do
    {:stop, :normal, state}
  end

  defp maybe_wipe_and_stop(%{ephemeral?: true, ghost_config: config} = state) do
    case config.wipe_strategy do
      :immediate ->
        execute_wipe(state)
        {:stop, :normal, %{state | phase: :wiping}}

      :delayed ->
        delay_ms = (config.wipe_delay_seconds || 0) * 1000
        Process.send_after(self(), {:execute_delayed_wipe, state.session_id}, delay_ms)
        {:noreply, %{state | phase: :awaiting_wipe}}

      :scheduled ->
        delay_ms = (config.wipe_delay_seconds || 0) * 1000
        Process.send_after(self(), {:execute_delayed_wipe, state.session_id}, delay_ms)
        {:noreply, %{state | phase: :awaiting_wipe}}
    end
  end

  defp execute_wipe(%{session_id: session_id}) do
    WipeEngine.execute_wipe(session_id)
  rescue
    e ->
      Logger.error("[Session] Wipe failed for #{session_id}: #{Exception.message(e)}")
  end

  defp force_terminate_expired(state) do
    %{session: session} = state

    Logger.warning("[Session] Force-terminating expired session #{session.id}")

    agents = refresh_agents(session.id)
    completed_agents = Enum.filter(agents, &(&1.status == :completed))

    state =
      case completed_agents do
        [] ->
          state

        _ ->
          %{state | agents: agents}
          |> run_verdict_phase()
      end

    {:ok, session} =
      if state.session.status != :completed do
        Deliberation.update_analysis_session(state.session, %{
          status: :timed_out,
          completed_at: DateTime.utc_now(:second),
          error_message: "max_session_duration_exceeded"
        })
      else
        {:ok, state.session}
      end

    Accounts.create_audit_entry(%{
      action: "ghost_protocol.session_expired",
      resource_type: "analysis_session",
      resource_id: session.id,
      workspace_id: session.workspace_id,
      metadata: %{
        "reason" => "max_session_duration_exceeded",
        "partial_verdict" => completed_agents != []
      }
    })

    broadcast_expiry(session)

    if state.ephemeral? do
      execute_wipe(state)
    end

    %{state | session: session, phase: :timed_out}
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp validate_same_workspace(event, workflow) do
    if event.workspace_id == workflow.workspace_id do
      :ok
    else
      {:error, :workspace_mismatch}
    end
  end

  defp existing_session(event_id) do
    case Registry.lookup(@registry, event_id) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: :none

      _ ->
        :none
    end
  end

  defp via_tuple(event_id) do
    {:via, Registry, {@registry, event_id}}
  end

  defp load_full_workflow(workflow_id) do
    Workflows.get_workflow!(workflow_id)
  end

  defp load_ghost_config(%{ghost_protocol_config_id: nil}), do: nil

  defp load_ghost_config(%{ghost_protocol_config_id: config_id}) when is_binary(config_id) do
    Swarmshield.GhostProtocol.get_config!(config_id)
  end

  defp load_ghost_config(_), do: nil

  defp load_consensus_policy(workflow, opts) do
    case Keyword.get(opts, :consensus_policy_id) do
      nil -> find_or_default_policy(workflow.workspace_id)
      policy_id -> Workflows.get_consensus_policy!(policy_id)
    end
  end

  defp find_or_default_policy(workspace_id) when is_binary(workspace_id) do
    {policies, _count} = Workflows.list_consensus_policies(workspace_id, page: 1, page_size: 1)

    case policies do
      [policy | _] -> policy
      [] -> create_default_policy(workspace_id)
    end
  end

  defp create_default_policy(workspace_id) do
    {:ok, policy} =
      Workflows.create_consensus_policy(workspace_id, %{
        name: "Default Majority Vote",
        description: "Auto-created default policy — simple majority vote",
        strategy: :majority,
        threshold: 0.5,
        enabled: true
      })

    policy
  end

  defp compute_expires_at(nil, _now), do: nil

  defp compute_expires_at(%{max_session_duration_seconds: duration}, now)
       when is_integer(duration) do
    DateTime.add(now, duration, :second)
  end

  defp compute_expires_at(_, _now), do: nil

  defp compute_content_hash(false, _content), do: nil

  defp compute_content_hash(true, content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp compute_content_hash(true, _), do: nil

  defp create_session_record(event, workflow, consensus_policy, expires_at, input_content_hash) do
    Deliberation.create_analysis_session(%{
      workspace_id: event.workspace_id,
      workflow_id: workflow.id,
      consensus_policy_id: consensus_policy.id,
      agent_event_id: event.id,
      status: :pending,
      trigger: :automatic,
      expires_at: expires_at,
      input_content_hash: input_content_hash,
      metadata: %{}
    })
  end

  defp schedule_expiry(nil, _config), do: :ok

  defp schedule_expiry(_expires_at, nil), do: :ok

  defp schedule_expiry(expires_at, %{auto_terminate_on_expiry: true}) do
    delay_ms = max(DateTime.diff(expires_at, DateTime.utc_now(:second), :millisecond), 1000)
    Process.send_after(self(), :check_expiry, delay_ms)
  end

  defp schedule_expiry(_, _), do: :ok

  defp expired?(%{expires_at: nil}), do: false

  defp expired?(%{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(:second), expires_at) != :lt
  end

  defp render_system_prompt(agent_def, %{prompt_template_id: nil}) do
    agent_def.system_prompt || "You are a security analyst."
  end

  defp render_system_prompt(agent_def, %{prompt_template: nil}) do
    agent_def.system_prompt || "You are a security analyst."
  end

  defp render_system_prompt(agent_def, %{prompt_template: template}) do
    base_prompt = agent_def.system_prompt || "You are a security analyst."

    variables = %{
      "system_prompt" => base_prompt,
      "role" => agent_def.role || "analyst",
      "expertise" => Enum.join(agent_def.expertise || [], ", ")
    }

    case PromptRenderer.render(template.template, variables) do
      {:ok, rendered} -> rendered
      _ -> base_prompt
    end
  end

  defp build_deliberation_prompt(agent_def) do
    base = agent_def.system_prompt || "You are a security analyst."

    base <>
      "\n\nYou are in the deliberation phase. Review other agents' analyses and provide your response. " <>
      "If you agree with the majority, explain why. If you disagree, provide counter-arguments. " <>
      "End your response with your current VOTE (ALLOW, FLAG, or BLOCK) and CONFIDENCE (0.0-1.0)."
  end

  defp parse_llm_vote(text) when is_binary(text) do
    vote = extract_vote(text)
    confidence = extract_confidence(text)
    {vote, confidence}
  end

  defp parse_llm_vote(_), do: {nil, nil}

  @vote_pattern ~r/VOTE\s*:\s*(BLOCK|FLAG|ALLOW)/i
  @verdict_pattern ~r/VERDICT.*?(BLOCK|FLAG)/i

  defp extract_vote(text) do
    case Regex.run(@vote_pattern, text) do
      [_, match] -> vote_from_string(String.upcase(match))
      nil -> extract_vote_from_verdict(text)
    end
  end

  defp extract_vote_from_verdict(text) do
    case Regex.run(@verdict_pattern, text) do
      [_, match] -> vote_from_string(String.upcase(match))
      nil -> :flag
    end
  end

  defp vote_from_string("BLOCK"), do: :block
  defp vote_from_string("FLAG"), do: :flag
  defp vote_from_string("ALLOW"), do: :allow
  defp vote_from_string(_), do: :flag

  defp extract_confidence(text) do
    case Regex.run(~r/(?:CONFIDENCE|confidence)[:\s]*([01]\.?\d*)/, text) do
      [_, value] ->
        case Float.parse(value) do
          {f, _} when f >= 0.0 and f <= 1.0 -> f
          _ -> 0.5
        end

      _ ->
        0.5
    end
  end

  defp refresh_agents(session_id) do
    Deliberation.list_agent_instances(session_id)
  end

  defp build_votes(agents) do
    agents
    |> Enum.filter(&(&1.vote in @vote_allowlist))
    |> Enum.map(fn agent ->
      %{
        vote: agent.vote,
        confidence: agent.confidence || 0.5,
        agent_id: agent.id,
        weight: 1.0
      }
    end)
  end

  defp evaluate_consensus(votes, policy) do
    case Consensus.evaluate(votes, policy) do
      {:consensus, decision, details} -> {:consensus, decision, details}
      {:no_consensus, details} -> {:no_consensus, :escalate, details}
    end
  end

  defp build_dissenting(agents, decision, :consensus) do
    agents
    |> Enum.filter(&(&1.vote != nil and &1.vote != decision))
    |> Enum.map(fn agent ->
      %{
        "agent_id" => agent.id,
        "vote" => to_string(agent.vote),
        "confidence" => agent.confidence
      }
    end)
  end

  defp build_dissenting(_agents, _decision, :no_consensus), do: []

  defp build_reasoning(:consensus, decision, details) do
    "Consensus reached via #{Map.get(details, :strategy, "majority")} strategy. " <>
      "Decision: #{decision}. " <>
      "Vote count: #{inspect(Map.get(details, :vote_breakdown, %{}))}."
  end

  defp build_reasoning(:no_consensus, _decision, details) do
    "No consensus reached. Escalating for manual review. " <>
      "Vote breakdown: #{inspect(Map.get(details, :vote_breakdown, %{}))}."
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  @verdict_to_event_status %{
    block: :blocked,
    allow: :allowed,
    flag: :flagged
  }

  defp update_event_status(event, decision) do
    case Map.get(@verdict_to_event_status, decision) do
      nil -> :ok
      status -> Swarmshield.Gateway.update_agent_event_status(event, status)
    end
  end

  defp fail_session(state, session, error_message) do
    {:ok, session} =
      Deliberation.update_analysis_session(session, %{
        status: :failed,
        completed_at: DateTime.utc_now(:second),
        error_message: error_message
      })

    %{state | session: session, phase: :failed}
  end

  defp audit_verdict(session, verdict) do
    session_id = session.id
    workspace_id = session.workspace_id
    verdict_id = verdict.id
    decision = to_string(verdict.decision)
    consensus_reached = verdict.consensus_reached

    Task.Supervisor.start_child(
      Swarmshield.TaskSupervisor,
      fn ->
        try do
          Accounts.create_audit_entry(%{
            action: "deliberation.verdict_created",
            resource_type: "verdict",
            resource_id: verdict_id,
            workspace_id: workspace_id,
            metadata: %{
              "session_id" => session_id,
              "decision" => decision,
              "consensus_reached" => consensus_reached
            }
          })
        catch
          _kind, _reason -> :ok
        end
      end
    )
  end

  defp deliberation_rounds(workflow, opts) do
    Keyword.get(
      opts,
      :deliberation_rounds,
      Map.get(workflow, :metadata, %{})
      |> Map.get("deliberation_rounds", @default_deliberation_rounds)
    )
  end

  defp merge_agents(existing, updated) do
    updated_ids = MapSet.new(updated, & &1.id)

    not_updated = Enum.reject(existing, &(&1.id in updated_ids))
    not_updated ++ updated
  end

  defp broadcast_phase(session, event, payload) do
    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "deliberation:#{session.id}",
      {event, session.id, payload}
    )

    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "deliberations:#{session.workspace_id}",
      {event, session.id, payload}
    )
  end

  defp broadcast_expiry(session) do
    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "ghost_protocol:#{session.id}",
      {:session_expired, session.id}
    )

    Phoenix.PubSub.broadcast(
      Swarmshield.PubSub,
      "ghost_protocol:#{session.workspace_id}",
      {:session_expired, session.id}
    )
  end

  defp maybe_add_backend(opts, nil), do: opts
  defp maybe_add_backend(opts, backend), do: Keyword.put(opts, :backend, backend)
end
