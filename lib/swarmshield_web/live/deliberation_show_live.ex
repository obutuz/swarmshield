defmodule SwarmshieldWeb.DeliberationShowLive do
  @moduledoc """
  Real-time deliberation viewer showing live debate between AI agents.

  Displays session info, agent panels with assessments and votes,
  chronological message timeline grouped by round, verdict panel,
  and GhostProtocol lifecycle visualization for ephemeral sessions.
  Subscribes to PubSub for real-time message and verdict updates.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Deliberation
  alias SwarmshieldWeb.Hooks.AuthHooks

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Deliberation Details")}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "deliberations:view") do
      {:noreply, load_session(socket, id)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view deliberations.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  @impl true
  def handle_info({:message_created, message_id, _message_type}, socket) do
    case Deliberation.get_deliberation_message(message_id) do
      nil ->
        {:noreply, socket}

      message ->
        enriched = Map.put(message, :agent_name, message.agent_instance.agent_definition.name)
        {:noreply, stream_insert(socket, :messages, enriched)}
    end
  end

  def handle_info({:verdict_reached, _verdict_id, _decision}, socket) do
    session_id = socket.assigns.session.id
    verdict = Deliberation.get_verdict_by_session(session_id)
    {:noreply, assign(socket, :session, %{socket.assigns.session | verdict: verdict})}
  end

  def handle_info({:session_updated, _session_id, new_status}, socket) do
    {:noreply, assign(socket, :session, %{socket.assigns.session | status: new_status})}
  end

  def handle_info({:session_created, _session_id, new_status}, socket) do
    {:noreply, assign(socket, :session, %{socket.assigns.session | status: new_status})}
  end

  def handle_info({:wipe_completed, _session_id}, socket) do
    session_id = socket.assigns.session.id
    workspace_id = socket.assigns.current_workspace.id
    {:noreply, load_session(socket, session_id, workspace_id)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp load_session(socket, id, workspace_id \\ nil) do
    ws_id = workspace_id || socket.assigns.current_workspace.id

    case Deliberation.get_full_session_for_workspace(id, ws_id) do
      nil ->
        socket
        |> put_flash(:error, "Deliberation session not found.")
        |> redirect(to: ~p"/deliberations")

      session ->
        if connected?(socket) do
          Deliberation.subscribe_to_session(session.id)
          Swarmshield.GhostProtocol.subscribe_to_session(session.id)
        end

        messages = collect_messages(session.agent_instances)

        socket
        |> assign(:session, session)
        |> assign(:ephemeral?, ephemeral?(session))
        |> stream(:messages, messages, reset: true)
    end
  end

  defp collect_messages(agent_instances) do
    agent_instances
    |> Enum.flat_map(fn instance ->
      Enum.map(instance.deliberation_messages, fn msg ->
        Map.put(msg, :agent_name, instance.agent_definition.name)
      end)
    end)
    |> Enum.sort_by(& &1.inserted_at, DateTime)
  end

  defp ephemeral?(%{workflow: %{ghost_protocol_config: config}}) when not is_nil(config), do: true
  defp ephemeral?(_session), do: false

  # -------------------------------------------------------------------
  # Template
  # -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:deliberations}
    >
      <div class="space-y-6">
        <%!-- Back link + Header --%>
        <div id="session-header">
          <.link
            navigate={~p"/deliberations"}
            class="inline-flex items-center gap-1 text-sm text-base-content/40 hover:text-base-content/60 transition-colors mb-4"
          >
            <.icon name="hero-arrow-left-mini" class="size-4" /> Back to Deliberations
          </.link>

          <div class="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4">
            <div>
              <h1 class="text-2xl font-bold tracking-tight">Deliberation Session</h1>
              <p class="text-sm text-base-content/50 mt-1">
                {workflow_name(@session)} &middot; {format_trigger(@session.trigger)}
              </p>
            </div>
            <div class="flex items-center gap-2">
              <.session_status_badge status={@session.status} />
              <span
                :if={@ephemeral?}
                class="inline-flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-medium bg-secondary/10 text-secondary"
              >
                <.icon name="hero-eye-slash" class="size-3" /> GhostProtocol
              </span>
            </div>
          </div>
        </div>

        <%!-- Session Info Cards --%>
        <div id="session-info" class="grid grid-cols-2 sm:grid-cols-4 gap-4">
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
            <p class="text-xs font-medium text-base-content/40 uppercase tracking-wider">Started</p>
            <p class="text-sm font-semibold mt-1">{format_datetime(@session.started_at)}</p>
          </div>
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
            <p class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
              Duration
            </p>
            <p class="text-sm font-semibold mt-1">{format_duration(@session)}</p>
          </div>
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
            <p class="text-xs font-medium text-base-content/40 uppercase tracking-wider">Tokens</p>
            <p class="text-sm font-semibold tabular-nums mt-1">
              {format_number(@session.total_tokens_used)}
            </p>
          </div>
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
            <p class="text-xs font-medium text-base-content/40 uppercase tracking-wider">Cost</p>
            <p class="text-sm font-semibold tabular-nums mt-1">
              {format_cost(@session.total_cost_cents)}
            </p>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <%!-- Main Column: Message Timeline --%>
          <div class="lg:col-span-2 space-y-6">
            <%!-- Agent Panels --%>
            <div id="agent-panels" class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div
                :for={instance <- @session.agent_instances}
                class="rounded-xl border border-base-300/50 bg-base-100 p-4"
              >
                <div class="flex items-center gap-3 mb-3">
                  <div class="flex items-center justify-center size-8 rounded-lg bg-primary/10">
                    <.icon name="hero-user-circle" class="size-5 text-primary" />
                  </div>
                  <div>
                    <p class="text-sm font-medium">{instance.agent_definition.name}</p>
                    <p class="text-xs text-base-content/40">{instance.role}</p>
                  </div>
                </div>
                <div :if={instance.initial_assessment} class="text-xs text-base-content/60 mb-2">
                  <p class="line-clamp-3">{instance.initial_assessment}</p>
                </div>
                <div class="flex items-center gap-3 mt-auto pt-2 border-t border-base-300/30">
                  <span
                    :if={instance.vote}
                    class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                      vote_classes(instance.vote)
                    ]}
                  >
                    Vote: {instance.vote}
                  </span>
                  <span :if={instance.confidence} class="text-xs tabular-nums text-base-content/50">
                    {Float.round(instance.confidence * 100, 1)}% confidence
                  </span>
                </div>
              </div>
            </div>

            <%!-- Message Timeline --%>
            <div id="message-timeline" class="rounded-xl border border-base-300/50 bg-base-100 p-4">
              <h3 class="text-sm font-medium text-base-content/50 mb-4">
                <.icon name="hero-chat-bubble-left-right" class="size-4 inline-block mr-1" />
                Debate Timeline
              </h3>
              <div id="messages-stream" phx-update="stream" class="space-y-3">
                <div
                  :for={{dom_id, message} <- @streams.messages}
                  id={dom_id}
                  class={[
                    "rounded-lg p-3 border-l-4",
                    message_classes(message.message_type)
                  ]}
                >
                  <div class="flex items-center justify-between mb-1">
                    <div class="flex items-center gap-2">
                      <span class="text-xs font-medium">{message.agent_name}</span>
                      <span class={[
                        "px-1.5 py-0.5 rounded text-[10px] font-medium uppercase",
                        message_type_badge_classes(message.message_type)
                      ]}>
                        {format_message_type(message.message_type)}
                      </span>
                      <span class="text-[10px] text-base-content/30">Round {message.round}</span>
                    </div>
                    <span class="text-[10px] text-base-content/30 tabular-nums">
                      {format_time(message.inserted_at)}
                    </span>
                  </div>
                  <p class="text-sm text-base-content/70 whitespace-pre-wrap">{message.content}</p>
                </div>
              </div>

              <div
                :if={
                  Enum.empty?(@session.agent_instances) or
                    Enum.all?(@session.agent_instances, &Enum.empty?(&1.deliberation_messages))
                }
                id="messages-empty"
                class="py-8 text-center"
              >
                <.icon
                  name="hero-chat-bubble-left-right"
                  class="size-8 text-base-content/20 mx-auto mb-2"
                />
                <p class="text-sm text-base-content/40">No messages yet</p>
              </div>
            </div>
          </div>

          <%!-- Sidebar: Verdict + GhostProtocol --%>
          <div class="space-y-6">
            <%!-- Verdict Panel --%>
            <div
              :if={@session.verdict}
              id="verdict-panel"
              class="rounded-xl border border-base-300/50 bg-base-100 p-4"
            >
              <h3 class="text-sm font-medium text-base-content/50 mb-3">
                <.icon name="hero-scale" class="size-4 inline-block mr-1" /> Verdict
              </h3>
              <div class="space-y-3">
                <div class="flex items-center gap-3">
                  <.verdict_decision_badge decision={@session.verdict.decision} />
                  <span class="text-sm tabular-nums font-medium">
                    {Float.round(@session.verdict.confidence * 100, 1)}% confidence
                  </span>
                </div>
                <div>
                  <p class="text-xs font-medium text-base-content/40 mb-1">Reasoning</p>
                  <p class="text-sm text-base-content/70">{@session.verdict.reasoning}</p>
                </div>
                <div :if={@session.verdict.consensus_reached}>
                  <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-success/10 text-success">
                    <.icon name="hero-check-circle" class="size-3" /> Consensus Reached
                  </span>
                </div>
                <div :if={not Enum.empty?(@session.verdict.dissenting_opinions)}>
                  <p class="text-xs font-medium text-base-content/40 mb-1">Dissenting Opinions</p>
                  <div
                    :for={opinion <- @session.verdict.dissenting_opinions}
                    class="text-xs text-base-content/50 bg-base-200/50 rounded p-2 mb-1"
                  >
                    {opinion["agent_name"] || "Agent"}: {opinion["reasoning"] || opinion["reason"]}
                  </div>
                </div>
              </div>
            </div>

            <%!-- No verdict yet --%>
            <div
              :if={!@session.verdict}
              id="no-verdict"
              class="rounded-xl border border-base-300/50 bg-base-100 p-4 text-center"
            >
              <.icon name="hero-scale" class="size-8 text-base-content/20 mx-auto mb-2" />
              <p class="text-sm text-base-content/40">Verdict pending</p>
              <p class="text-xs text-base-content/30 mt-1">
                Agents are still deliberating...
              </p>
            </div>

            <%!-- GhostProtocol Panel --%>
            <div
              :if={@ephemeral?}
              id="ghost-protocol-panel"
              class="rounded-xl border border-secondary/30 bg-secondary/5 p-4"
            >
              <h3 class="text-sm font-medium text-secondary mb-3">
                <.icon name="hero-eye-slash" class="size-4 inline-block mr-1" /> GhostProtocol
              </h3>
              <div class="space-y-3">
                <div class="flex items-center gap-2">
                  <p class="text-xs text-base-content/40">Strategy</p>
                  <span class="text-xs font-medium">
                    {@session.workflow.ghost_protocol_config.wipe_strategy}
                  </span>
                </div>
                <div
                  :if={@session.workflow.ghost_protocol_config.crypto_shred}
                  class="flex items-center gap-2"
                >
                  <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium bg-error/10 text-error">
                    <.icon name="hero-lock-closed" class="size-3" /> Crypto Shred
                  </span>
                </div>
                <div :if={@session.expires_at}>
                  <p class="text-xs text-base-content/40">Expires</p>
                  <p class="text-xs font-mono tabular-nums">
                    {Calendar.strftime(@session.expires_at, "%H:%M:%S UTC")}
                  </p>
                </div>
                <div class="flex items-center gap-2">
                  <p class="text-xs text-base-content/40">Max Duration</p>
                  <span class="text-xs font-medium">
                    {@session.workflow.ghost_protocol_config.max_session_duration_seconds}s
                  </span>
                </div>
              </div>
            </div>

            <%!-- Session Error --%>
            <div
              :if={@session.error_message}
              id="session-error"
              class="rounded-xl border border-error/30 bg-error/5 p-4"
            >
              <h3 class="text-sm font-medium text-error mb-2">
                <.icon name="hero-exclamation-triangle" class="size-4 inline-block mr-1" /> Error
              </h3>
              <p class="text-xs text-error/80">{@session.error_message}</p>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Components
  # -------------------------------------------------------------------

  attr :status, :atom, required: true

  defp session_status_badge(%{status: :pending} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-base-300/30 text-base-content/60">
      <.icon name="hero-clock" class="size-3" /> Pending
    </span>
    """
  end

  defp session_status_badge(%{status: :analyzing} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-info/10 text-info">
      <.icon name="hero-magnifying-glass" class="size-3 animate-pulse" /> Analyzing
    </span>
    """
  end

  defp session_status_badge(%{status: :deliberating} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-primary/10 text-primary">
      <.icon name="hero-chat-bubble-left-right" class="size-3" /> Deliberating
    </span>
    """
  end

  defp session_status_badge(%{status: :voting} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-accent/10 text-accent">
      <.icon name="hero-hand-raised" class="size-3" /> Voting
    </span>
    """
  end

  defp session_status_badge(%{status: :completed} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-success/10 text-success">
      <.icon name="hero-check-circle" class="size-3" /> Completed
    </span>
    """
  end

  defp session_status_badge(%{status: :failed} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-error/10 text-error">
      <.icon name="hero-x-circle" class="size-3" /> Failed
    </span>
    """
  end

  defp session_status_badge(%{status: :timed_out} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-warning/10 text-warning">
      <.icon name="hero-clock" class="size-3" /> Timed Out
    </span>
    """
  end

  defp session_status_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-sm">{@status}</span>
    """
  end

  attr :decision, :atom, required: true

  defp verdict_decision_badge(%{decision: :block} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-bold bg-error/10 text-error">
      Block
    </span>
    """
  end

  defp verdict_decision_badge(%{decision: :flag} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-bold bg-warning/10 text-warning">
      Flag
    </span>
    """
  end

  defp verdict_decision_badge(%{decision: :allow} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-bold bg-success/10 text-success">
      Allow
    </span>
    """
  end

  defp verdict_decision_badge(%{decision: :escalate} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-bold bg-primary/10 text-primary">
      Escalate
    </span>
    """
  end

  defp verdict_decision_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost">{@decision}</span>
    """
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp workflow_name(%{workflow: %{name: name}}) when is_binary(name), do: name
  defp workflow_name(_session), do: "Unknown Workflow"

  defp format_trigger(:automatic), do: "Automatic"
  defp format_trigger(:manual), do: "Manual"
  defp format_trigger(trigger), do: to_string(trigger)

  defp format_datetime(nil), do: "Not started"

  defp format_datetime(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%b %d, %Y %H:%M:%S UTC")

  defp format_datetime(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> format_datetime()

  defp format_duration(%{started_at: nil}), do: "—"
  defp format_duration(%{completed_at: nil, started_at: _}), do: "In progress..."

  defp format_duration(%{started_at: started, completed_at: completed}) do
    diff = DateTime.diff(completed, started, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
    end
  end

  defp format_number(0), do: "0"
  defp format_number(nil), do: "0"

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp format_cost(0), do: "$0.00"
  defp format_cost(nil), do: "$0.00"
  defp format_cost(cents), do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp format_time(nil), do: ""

  defp format_time(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_time(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> format_time()

  defp format_message_type(:analysis), do: "Analysis"
  defp format_message_type(:argument), do: "Argument"
  defp format_message_type(:counter_argument), do: "Counter"
  defp format_message_type(:evidence), do: "Evidence"
  defp format_message_type(:summary), do: "Summary"
  defp format_message_type(:vote_rationale), do: "Vote"
  defp format_message_type(type), do: type |> to_string() |> String.capitalize()

  defp message_classes(:analysis), do: "border-info/50 bg-info/5"
  defp message_classes(:argument), do: "border-success/50 bg-success/5"
  defp message_classes(:counter_argument), do: "border-warning/50 bg-warning/5"
  defp message_classes(:evidence), do: "border-accent/50 bg-accent/5"
  defp message_classes(:summary), do: "border-primary/50 bg-primary/5"
  defp message_classes(:vote_rationale), do: "border-secondary/50 bg-secondary/5"
  defp message_classes(_), do: "border-base-300/50 bg-base-200/30"

  defp message_type_badge_classes(:analysis), do: "bg-info/10 text-info"
  defp message_type_badge_classes(:argument), do: "bg-success/10 text-success"
  defp message_type_badge_classes(:counter_argument), do: "bg-warning/10 text-warning"
  defp message_type_badge_classes(:evidence), do: "bg-accent/10 text-accent"
  defp message_type_badge_classes(:summary), do: "bg-primary/10 text-primary"
  defp message_type_badge_classes(:vote_rationale), do: "bg-secondary/10 text-secondary"
  defp message_type_badge_classes(_), do: "bg-base-300/30 text-base-content/60"

  defp vote_classes(:allow), do: "bg-success/10 text-success"
  defp vote_classes(:flag), do: "bg-warning/10 text-warning"
  defp vote_classes(:block), do: "bg-error/10 text-error"
  defp vote_classes(_), do: "bg-base-300/30 text-base-content/60"
end
