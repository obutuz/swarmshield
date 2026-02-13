defmodule SwarmshieldWeb.EventShowLive do
  @moduledoc """
  Event detail view showing full event data, policy evaluation results,
  matched rules, linked violations, and linked deliberation session.

  If the session was ephemeral (GhostProtocol), shows badge and [WIPED]
  for wiped message fields.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Deliberation
  alias Swarmshield.Gateway
  alias Swarmshield.Policies
  alias SwarmshieldWeb.Hooks.AuthHooks

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Event Details")}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "events:view") do
      {:noreply, load_event(socket, id)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view events.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  defp load_event(socket, event_id) do
    workspace_id = socket.assigns.current_workspace.id

    case Gateway.get_agent_event_for_workspace(event_id, workspace_id) do
      nil ->
        socket
        |> put_flash(:error, "Event not found.")
        |> redirect(to: ~p"/events")

      event ->
        {violations, _count} =
          Policies.list_policy_violations(workspace_id,
            agent_event_id: event.id,
            page_size: 100
          )

        session = Deliberation.get_session_for_event(event.id)

        is_ephemeral? =
          case session do
            %{workflow: %{ghost_protocol_config: config}} when not is_nil(config) -> true
            _ -> false
          end

        socket
        |> assign(:event, event)
        |> assign(:violations, violations)
        |> assign(:session, session)
        |> assign(:is_ephemeral?, is_ephemeral?)
        |> assign(:page_title, "Event #{String.slice(event.id, 0..7)}")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:events}
    >
      <div class="space-y-6">
        <%!-- Back navigation --%>
        <div>
          <.link
            navigate={~p"/events"}
            class="inline-flex items-center gap-1 text-sm text-base-content/50 hover:text-base-content transition-colors"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to Events
          </.link>
        </div>

        <%!-- Event Header --%>
        <div
          id="event-header"
          class="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4"
        >
          <div class="space-y-2">
            <div class="flex items-center gap-3">
              <h1 class="text-2xl font-bold tracking-tight">Event Details</h1>
              <.status_badge status={@event.status} />
              <.ghost_badge :if={@is_ephemeral?} />
            </div>
            <p class="text-xs text-base-content/40 font-mono">{@event.id}</p>
          </div>
        </div>

        <%!-- ============================================================ --%>
        <%!-- SECTION 1: Deliberation & Verdict (results first)            --%>
        <%!-- ============================================================ --%>

        <%!-- Deliberation Session Strip + Quick Info --%>
        <div
          :if={@session}
          id="linked-session"
          class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden"
        >
          <div class="px-5 py-3 border-b border-base-300/30 flex items-center gap-2">
            <.icon name="hero-chat-bubble-left-right" class="size-4 text-primary" />
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
              Deliberation
            </h2>
            <.ghost_badge :if={@is_ephemeral?} />
          </div>
          <div class="px-5 py-3">
            <div class="flex flex-wrap items-center gap-x-6 gap-y-2">
              <div class="flex items-center gap-2 text-sm">
                <span class="text-xs text-base-content/50">Session</span>
                <.link
                  navigate={~p"/deliberations/#{@session.id}"}
                  class="text-primary hover:underline font-mono text-xs"
                >
                  {String.slice(@session.id, 0..7)}...
                </.link>
              </div>
              <div class="flex items-center gap-2 text-sm">
                <span class="text-xs text-base-content/50">Status</span>
                <.session_status_badge status={@session.status} />
              </div>
              <div class="flex items-center gap-2 text-sm">
                <span class="text-xs text-base-content/50">Trigger</span>
                <span class="text-xs">{@session.trigger || "-"}</span>
              </div>
              <div class="flex items-center gap-2 text-sm">
                <span class="text-xs text-base-content/50">Violations</span>
                <span class="text-xs tabular-nums font-medium">{length(@violations)}</span>
              </div>
              <div class="flex items-center gap-2 text-sm">
                <span class="text-xs text-base-content/50">Workspace</span>
                <span class="text-xs">{@current_workspace.name}</span>
              </div>
            </div>
          </div>
        </div>

        <%!-- No Session Card --%>
        <div
          :if={is_nil(@session)}
          id="no-session"
          class="rounded-xl border border-base-300/50 bg-base-100 p-5 text-center"
        >
          <.icon
            name="hero-chat-bubble-left-right"
            class="size-8 text-base-content/20 mx-auto mb-2"
          />
          <p class="text-sm text-base-content/50">No deliberation session</p>
          <p class="text-xs text-base-content/30 mt-1">
            This event did not trigger a deliberation.
          </p>
        </div>

        <%!-- Verdict Summary Card --%>
        <div
          :if={@session && @session.verdict}
          id="verdict-summary"
          class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden"
        >
          <div class="px-5 py-3 border-b border-base-300/30 flex items-center gap-2">
            <.icon name="hero-scale" class="size-4 text-primary" />
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
              Final Verdict
            </h2>
          </div>
          <div class="p-5 space-y-5">
            <%!-- Decision + Confidence + Consensus --%>
            <div class="flex flex-wrap items-center gap-3">
              <span class={[
                "inline-flex items-center px-3 py-1 rounded-lg text-sm font-bold uppercase tracking-wide",
                verdict_decision_classes(@session.verdict.decision)
              ]}>
                {@session.verdict.decision}
              </span>
              <span
                :if={@session.verdict.confidence}
                class="text-sm text-base-content/70 tabular-nums"
              >
                Confidence:
                <span class="font-semibold">
                  {format_confidence(@session.verdict.confidence)}
                </span>
              </span>
              <span
                :if={@session.verdict.consensus_reached}
                class="inline-flex items-center gap-1 text-sm text-success"
              >
                <.icon name="hero-check-circle" class="size-4" /> Consensus
              </span>
              <span
                :if={not @session.verdict.consensus_reached}
                class="inline-flex items-center gap-1 text-sm text-warning"
              >
                <.icon name="hero-exclamation-circle" class="size-4" /> No Consensus
              </span>
            </div>

            <%!-- Vote Breakdown Bar --%>
            <div
              :if={@session.verdict.vote_breakdown != %{}}
              id="vote-breakdown"
            >
              <h3 class="text-xs font-medium text-base-content/50 mb-2">Vote Breakdown</h3>
              <div class="flex rounded-lg overflow-hidden h-6">
                <div
                  :for={
                    {vote_type, count} <-
                      vote_breakdown_sorted(@session.verdict.vote_breakdown)
                  }
                  :if={count > 0}
                  class={[
                    "flex items-center justify-center text-xs font-medium text-white",
                    vote_bar_color(vote_type)
                  ]}
                  style={"flex: #{count}"}
                >
                  {vote_type}: {count}
                </div>
              </div>
              <div class="flex flex-wrap gap-4 mt-2">
                <div
                  :for={
                    {vote_type, count} <-
                      vote_breakdown_sorted(@session.verdict.vote_breakdown)
                  }
                  class="flex items-center gap-1.5 text-xs text-base-content/60"
                >
                  <span class={["size-2.5 rounded-full", vote_dot_color(vote_type)]} />
                  <span class="capitalize">{vote_type}:</span>
                  <span class="font-medium tabular-nums">{count}</span>
                </div>
              </div>
            </div>

            <%!-- Agent Votes Grid --%>
            <div
              :if={agent_instances_with_votes(@session) != []}
              id="agent-votes"
            >
              <h3 class="text-xs font-medium text-base-content/50 mb-2">Agent Votes</h3>
              <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
                <div
                  :for={instance <- agent_instances_with_votes(@session)}
                  class={[
                    "rounded-lg border p-3 space-y-1.5",
                    agent_vote_bg(instance.vote)
                  ]}
                >
                  <p class="text-sm font-semibold truncate">
                    {agent_instance_name(instance)}
                  </p>
                  <p class="text-xs text-base-content/50 truncate">
                    {agent_instance_role(instance)}
                  </p>
                  <div class="flex items-center gap-2">
                    <span
                      :if={instance.vote}
                      class={[
                        "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium uppercase",
                        verdict_decision_classes(instance.vote)
                      ]}
                    >
                      {instance.vote}
                    </span>
                    <span
                      :if={instance.confidence}
                      class="text-xs tabular-nums text-base-content/60"
                    >
                      {format_confidence(instance.confidence)}
                    </span>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Reasoning --%>
            <div :if={@session.verdict.reasoning}>
              <h3 class="text-xs font-medium text-base-content/50 mb-2">Reasoning</h3>
              <div class="bg-base-200/50 rounded-lg p-4">
                <p class="text-sm text-base-content/80 whitespace-pre-wrap">
                  {if @is_ephemeral? and is_nil(@session.verdict.reasoning),
                    do: "[WIPED]",
                    else: build_display_reasoning(@session)}
                </p>
              </div>
            </div>

            <%!-- Footer: Strategy + Link --%>
            <div class="flex flex-wrap items-center justify-between gap-3 pt-3 border-t border-base-300/30">
              <span
                :if={@session.verdict.consensus_strategy_used}
                class="text-xs text-base-content/50"
              >
                Strategy:
                <span class="font-medium">
                  {format_strategy(@session.verdict.consensus_strategy_used)}
                </span>
              </span>
              <.link
                navigate={~p"/deliberations/#{@session.id}"}
                class="inline-flex items-center gap-1 text-sm text-primary hover:underline font-medium"
              >
                View Full Deliberation <.icon name="hero-arrow-right" class="size-4" />
              </.link>
            </div>
          </div>
        </div>

        <%!-- ============================================================ --%>
        <%!-- SECTION 2: Policy Results (evaluation + violations)          --%>
        <%!-- ============================================================ --%>

        <%!-- Evaluation Result Card --%>
        <div
          :if={@event.evaluation_result != %{}}
          id="evaluation-result"
          class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden"
        >
          <div class="px-5 py-3 border-b border-base-300/30">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
              Policy Evaluation
            </h2>
          </div>
          <div class="p-5 space-y-4">
            <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
              <.eval_stat
                label="Action"
                value={@event.evaluation_result["action"] || "-"}
              />
              <.eval_stat
                label="Rules Evaluated"
                value={@event.evaluation_result["evaluated_count"] || 0}
              />
              <.eval_stat
                label="Blocked"
                value={@event.evaluation_result["block_count"] || 0}
              />
              <.eval_stat
                label="Flagged"
                value={@event.evaluation_result["flag_count"] || 0}
              />
            </div>

            <%!-- Matched Rules --%>
            <div :if={matched_rules(@event) != []}>
              <h3 class="text-xs font-medium text-base-content/50 mb-2">Matched Rules</h3>
              <div class="space-y-2">
                <div
                  :for={rule <- matched_rules(@event)}
                  class="flex items-center gap-3 rounded-lg bg-base-200/50 px-3 py-2"
                >
                  <span class={[
                    "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                    rule_action_classes(rule["action"])
                  ]}>
                    {rule["action"]}
                  </span>
                  <span class="text-sm">{rule["rule_name"]}</span>
                  <span class="text-xs text-base-content/40 ml-auto">{rule["rule_type"]}</span>
                </div>
              </div>
            </div>

            <.detail_row :if={@event.flagged_reason} label="Reason">
              <p class="text-sm text-warning">{@event.flagged_reason}</p>
            </.detail_row>
          </div>
        </div>

        <%!-- Violations Card --%>
        <div
          :if={@violations != []}
          id="violations-section"
          class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden"
        >
          <div class="px-5 py-3 border-b border-base-300/30">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
              Policy Violations
              <span class="badge badge-sm badge-error ml-2">{length(@violations)}</span>
            </h2>
          </div>
          <div class="divide-y divide-base-300/30">
            <div :for={v <- @violations} class="p-5">
              <div class="flex items-start gap-4">
                <div class={[
                  "flex items-center justify-center size-10 rounded-lg shrink-0",
                  violation_severity_bg(v.severity)
                ]}>
                  <.icon
                    name="hero-exclamation-triangle"
                    class={["size-5", violation_severity_text(v.severity)]}
                  />
                </div>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center justify-between gap-2">
                    <h3 class="text-base font-semibold">
                      {v.details["rule_name"] || "Policy Rule"}
                    </h3>
                    <span
                      :if={v.resolved}
                      class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-success/10 text-success"
                    >
                      <.icon name="hero-check-circle" class="size-3" /> Resolved
                    </span>
                  </div>
                  <div class="flex flex-wrap items-center gap-2 mt-1.5">
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                      violation_severity_badge(v.severity)
                    ]}>
                      {v.severity}
                    </span>
                    <span class={[
                      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                      violation_action_badge(v.action_taken)
                    ]}>
                      {v.action_taken}
                    </span>
                    <span
                      :if={v.details["rule_type"]}
                      class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-base-200 text-base-content/60"
                    >
                      {v.details["rule_type"]}
                    </span>
                  </div>
                  <%!-- Extra details from the details map --%>
                  <div
                    :if={violation_extra_details(v.details) != []}
                    class="mt-2 space-y-1"
                  >
                    <div
                      :for={{key, value} <- violation_extra_details(v.details)}
                      class="text-xs text-base-content/50"
                    >
                      <span class="font-medium">{format_detail_key(key)}:</span>
                      <span class="ml-1">{to_string(value)}</span>
                    </div>
                  </div>
                  <p
                    :if={v.resolved && v.resolved_at}
                    class="text-xs text-base-content/40 mt-2"
                  >
                    Resolved {format_datetime(v.resolved_at)}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- ============================================================ --%>
        <%!-- SECTION 3: Event Data (the original input)                   --%>
        <%!-- ============================================================ --%>

        <%!-- Event Data Card --%>
        <div
          id="event-data"
          class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden"
        >
          <div class="px-5 py-3 border-b border-base-300/30">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
              Event Data
            </h2>
          </div>
          <div class="p-5 space-y-4">
            <.detail_row label="Type">
              <.type_badge type={@event.event_type} />
            </.detail_row>
            <.detail_row label="Severity">
              <span class={severity_color(@event.severity)}>
                {format_severity(@event.severity)}
              </span>
            </.detail_row>
            <.detail_row label="Content">
              <p class="text-sm whitespace-pre-wrap break-words">{@event.content}</p>
            </.detail_row>
            <.detail_row label="Agent">
              {agent_name(@event)}
            </.detail_row>
            <.detail_row :if={@event.source_ip} label="Source IP">
              <span class="font-mono text-xs">{@event.source_ip}</span>
            </.detail_row>
            <.detail_row label="Created">
              <span class="text-xs tabular-nums">{format_datetime(@event.inserted_at)}</span>
            </.detail_row>
            <.detail_row :if={@event.evaluated_at} label="Evaluated">
              <span class="text-xs tabular-nums">{format_datetime(@event.evaluated_at)}</span>
            </.detail_row>
          </div>
        </div>

        <%!-- Payload Card --%>
        <div
          :if={@event.payload != %{}}
          id="event-payload"
          class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden"
        >
          <div class="px-5 py-3 border-b border-base-300/30">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
              Payload
            </h2>
          </div>
          <div class="p-5">
            <pre class="text-xs font-mono bg-base-200/50 rounded-lg p-4 overflow-x-auto whitespace-pre-wrap break-words"><code>{format_json(@event.payload)}</code></pre>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Components
  # -------------------------------------------------------------------

  slot :inner_block, required: true
  attr :label, :string, required: true

  defp detail_row(assigns) do
    ~H"""
    <div class="flex flex-col sm:flex-row sm:items-start gap-1 sm:gap-4">
      <span class="text-xs font-medium text-base-content/50 sm:w-28 shrink-0">{@label}</span>
      <div class="text-sm text-base-content/80">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp eval_stat(assigns) do
    ~H"""
    <div class="rounded-lg bg-base-200/50 p-3 text-center">
      <p class="text-xs text-base-content/50">{@label}</p>
      <p class="text-lg font-bold tabular-nums mt-0.5">{@value}</p>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(%{status: :allowed} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-success/10 text-success">
      <span class="size-1.5 rounded-full bg-success" /> Allowed
    </span>
    """
  end

  defp status_badge(%{status: :flagged} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-warning/10 text-warning">
      <span class="size-1.5 rounded-full bg-warning" /> Flagged
    </span>
    """
  end

  defp status_badge(%{status: :blocked} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-error/10 text-error">
      <span class="size-1.5 rounded-full bg-error" /> Blocked
    </span>
    """
  end

  defp status_badge(%{status: :pending} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-base-300/30 text-base-content/50">
      <span class="size-1.5 rounded-full bg-base-content/30" /> Pending
    </span>
    """
  end

  defp status_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-sm">{@status}</span>
    """
  end

  attr :type, :atom, required: true

  defp type_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
      type_classes(@type)
    ]}>
      {format_type(@type)}
    </span>
    """
  end

  defp ghost_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-secondary/10 text-secondary">
      <.icon name="hero-eye-slash" class="size-3" /> Ephemeral
    </span>
    """
  end

  attr :status, :atom, required: true

  defp session_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
      session_status_classes(@status)
    ]}>
      {@status}
    </span>
    """
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp agent_name(%{registered_agent: %{name: name}}) when is_binary(name), do: name
  defp agent_name(_), do: "Unknown"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y at %H:%M:%S UTC")
  end

  defp format_datetime(_), do: "-"

  defp format_json(map) when is_map(map), do: Jason.encode!(map, pretty: true)
  defp format_json(_), do: "{}"

  defp matched_rules(%{evaluation_result: %{"matched_rules" => rules}}) when is_list(rules),
    do: rules

  defp matched_rules(_), do: []

  defp format_type(:tool_call), do: "Tool Call"
  defp format_type(type), do: type |> to_string() |> String.capitalize()

  defp type_classes(:action), do: "bg-info/10 text-info"
  defp type_classes(:output), do: "bg-primary/10 text-primary"
  defp type_classes(:tool_call), do: "bg-accent/10 text-accent"
  defp type_classes(:message), do: "bg-base-300/30 text-base-content/60"
  defp type_classes(:error), do: "bg-error/10 text-error"
  defp type_classes(_), do: "bg-base-300/30 text-base-content/60"

  defp severity_color(:critical), do: "text-error font-bold"
  defp severity_color(:error), do: "text-error/70"
  defp severity_color(:warning), do: "text-warning"
  defp severity_color(:info), do: "text-base-content/50"
  defp severity_color(_), do: "text-base-content/50"

  defp format_severity(:critical), do: "CRITICAL"
  defp format_severity(:error), do: "ERROR"
  defp format_severity(:warning), do: "WARNING"
  defp format_severity(:info), do: "INFO"
  defp format_severity(_), do: "-"

  defp rule_action_classes("block"), do: "bg-error/10 text-error"
  defp rule_action_classes("flag"), do: "bg-warning/10 text-warning"
  defp rule_action_classes(_), do: "bg-base-300/30 text-base-content/60"

  defp verdict_decision_classes(:allow), do: "bg-success/10 text-success"
  defp verdict_decision_classes(:flag), do: "bg-warning/10 text-warning"
  defp verdict_decision_classes(:block), do: "bg-error/10 text-error"
  defp verdict_decision_classes(:escalate), do: "bg-info/10 text-info"
  defp verdict_decision_classes(_), do: "bg-base-300/30 text-base-content/60"

  defp session_status_classes(:completed), do: "bg-success/10 text-success"
  defp session_status_classes(:failed), do: "bg-error/10 text-error"
  defp session_status_classes(:timed_out), do: "bg-warning/10 text-warning"
  defp session_status_classes(_), do: "bg-info/10 text-info"

  defp violation_severity_bg(:critical), do: "bg-error/10"
  defp violation_severity_bg(:high), do: "bg-error/10"
  defp violation_severity_bg(:medium), do: "bg-warning/10"
  defp violation_severity_bg(_), do: "bg-base-200"

  defp violation_severity_text(:critical), do: "text-error"
  defp violation_severity_text(:high), do: "text-error"
  defp violation_severity_text(:medium), do: "text-warning"
  defp violation_severity_text(_), do: "text-base-content/50"

  defp violation_severity_badge(:critical), do: "bg-error/10 text-error"
  defp violation_severity_badge(:high), do: "bg-error/10 text-error"
  defp violation_severity_badge(:medium), do: "bg-warning/10 text-warning"
  defp violation_severity_badge(_), do: "bg-base-200 text-base-content/50"

  defp violation_action_badge(:blocked), do: "bg-error/10 text-error"
  defp violation_action_badge(:flagged), do: "bg-warning/10 text-warning"
  defp violation_action_badge(_), do: "bg-base-200 text-base-content/50"

  @violation_standard_keys ~w(rule_name rule_type)
  defp violation_extra_details(details) when is_map(details) do
    details
    |> Enum.reject(fn {key, _val} -> key in @violation_standard_keys end)
    |> Enum.sort_by(fn {key, _val} -> key end)
  end

  defp violation_extra_details(_), do: []

  defp format_detail_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_confidence(confidence) when is_float(confidence) do
    "#{Float.round(confidence * 100, 1)}%"
  end

  defp format_confidence(_), do: "-"

  defp format_strategy(strategy) when is_binary(strategy) do
    strategy
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_strategy(_), do: "-"

  defp vote_breakdown_sorted(breakdown) when is_map(breakdown) do
    order = %{"block" => 0, "flag" => 1, "allow" => 2}

    breakdown
    |> Enum.sort_by(fn {key, _count} -> Map.get(order, key, 3) end)
  end

  defp vote_breakdown_sorted(_), do: []

  defp vote_bar_color("block"), do: "bg-error"
  defp vote_bar_color("flag"), do: "bg-warning"
  defp vote_bar_color("allow"), do: "bg-success"
  defp vote_bar_color(_), do: "bg-base-300"

  defp vote_dot_color("block"), do: "bg-error"
  defp vote_dot_color("flag"), do: "bg-warning"
  defp vote_dot_color("allow"), do: "bg-success"
  defp vote_dot_color(_), do: "bg-base-300"

  defp agent_vote_bg(:block), do: "border-error/30 bg-error/5"
  defp agent_vote_bg(:flag), do: "border-warning/30 bg-warning/5"
  defp agent_vote_bg(:allow), do: "border-success/30 bg-success/5"
  defp agent_vote_bg(_), do: "border-base-300/50 bg-base-200/30"

  defp agent_instances_with_votes(%{agent_instances: instances})
       when is_list(instances) do
    Enum.filter(instances, fn instance -> instance.vote != nil end)
  end

  defp agent_instances_with_votes(_), do: []

  defp agent_instance_name(%{agent_definition: %{name: name}}) when is_binary(name), do: name
  defp agent_instance_name(%{role: role}) when is_binary(role), do: role
  defp agent_instance_name(_), do: "Agent"

  defp agent_instance_role(%{agent_definition: %{role: role}}) when is_binary(role), do: role
  defp agent_instance_role(%{role: role}) when is_binary(role), do: role
  defp agent_instance_role(_), do: "-"

  # --- Assessment Summary Helpers ---

  defp build_display_reasoning(session) do
    agents = agent_instances_with_votes(session)

    findings =
      agents
      |> Enum.filter(&(&1.status == :completed and not is_nil(&1.initial_assessment)))
      |> Enum.map(fn agent ->
        name = agent_instance_name(agent)
        summary = summarize_assessment(agent.initial_assessment)
        {name, summary}
      end)
      |> Enum.reject(fn {_, s} -> is_nil(s) end)

    case findings do
      [] ->
        session.verdict.reasoning

      [{_name, finding}] ->
        finding

      _ ->
        findings
        |> Enum.map_join(". ", fn {name, summary} ->
          "#{name}: #{summary}"
        end)
    end
  end

  @section_headers ~r/^##?\s+(Summary|Analysis|Overview|Threat Assessment|Assessment|Determination|Event Classification)/im

  defp summarize_assessment(nil), do: nil
  defp summarize_assessment(""), do: nil

  defp summarize_assessment(text) do
    (extract_section_content(text) || extract_first_substantive(text))
    |> strip_markdown()
    |> truncate_at_sentence(200)
  end

  defp extract_section_content(text) do
    case Regex.split(@section_headers, text, parts: 2, include_captures: true) do
      [_, _header, body] ->
        body
        |> String.split(~r/\n##?\s/, parts: 2)
        |> List.first()
        |> String.replace(~r/^:\s*/, "")
        |> String.trim()
        |> case do
          "" -> nil
          content -> content
        end

      _ ->
        nil
    end
  end

  defp extract_first_substantive(text) do
    text
    |> String.split(~r/\n\n+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn para ->
      String.starts_with?(para, "#") or
        String.starts_with?(para, "---") or
        String.starts_with?(para, "|") or
        String.starts_with?(para, "VOTE:") or
        String.match?(para, ~r/^(I need to|Let me)\b/i)
    end)
    |> List.first(text)
  end

  defp strip_markdown(text) do
    text
    |> String.replace(~r/\*\*([^*]+)\*\*/, "\\1")
    |> String.replace(~r/^#+\s+/m, "")
    |> String.replace(~r/^[-*]\s+/m, "")
    |> String.replace(~r/^>\s+/m, "")
    |> String.replace(~r/---+/, "")
    |> String.replace(~r/\n{2,}/, " ")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.trim()
  end

  defp truncate_at_sentence(text, max_len) when byte_size(text) <= max_len, do: text

  defp truncate_at_sentence(text, max_len) do
    truncated = String.slice(text, 0, max_len)

    case String.split(truncated, ~r/(?<=[.!?])\s/, trim: true) do
      [_ | _] = sentences ->
        sentences
        |> Enum.reverse()
        |> tl()
        |> Enum.reverse()
        |> Enum.join(" ")
        |> case do
          "" -> truncated <> "..."
          result -> result
        end

      _ ->
        truncated <> "..."
    end
  end
end
