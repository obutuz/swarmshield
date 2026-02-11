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

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <%!-- Main content: 2 cols --%>
          <div class="lg:col-span-2 space-y-6">
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
                <div :for={v <- @violations} class="p-4 flex items-start gap-4">
                  <div class={[
                    "flex items-center justify-center size-8 rounded-lg shrink-0",
                    violation_severity_bg(v.severity)
                  ]}>
                    <.icon
                      name="hero-exclamation-triangle"
                      class={["size-4", violation_severity_text(v.severity)]}
                    />
                  </div>
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center gap-2">
                      <span class="text-sm font-medium">
                        {v.details["rule_name"] || "Policy Rule"}
                      </span>
                      <span class={[
                        "inline-flex items-center px-1.5 py-0.5 rounded text-xs font-medium",
                        violation_severity_badge(v.severity)
                      ]}>
                        {v.severity}
                      </span>
                    </div>
                    <p class="text-xs text-base-content/50 mt-0.5">
                      Action: {v.action_taken} | Type: {v.details["rule_type"] || "-"}
                    </p>
                  </div>
                  <span :if={v.resolved} class="badge badge-success badge-sm">Resolved</span>
                </div>
              </div>
            </div>
          </div>

          <%!-- Sidebar: 1 col --%>
          <div class="space-y-6">
            <%!-- Deliberation Session Card --%>
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
              <div class="p-5 space-y-3">
                <.detail_row label="Session">
                  <.link
                    navigate={~p"/deliberations/#{@session.id}"}
                    class="text-sm text-primary hover:underline font-mono"
                  >
                    {String.slice(@session.id, 0..7)}...
                  </.link>
                </.detail_row>
                <.detail_row label="Status">
                  <.session_status_badge status={@session.status} />
                </.detail_row>
                <.detail_row label="Trigger">
                  <span class="text-sm">{@session.trigger || "-"}</span>
                </.detail_row>

                <%!-- Verdict --%>
                <div :if={@session.verdict} class="pt-3 border-t border-base-300/30">
                  <h3 class="text-xs font-medium text-base-content/50 mb-2">Verdict</h3>
                  <div class="space-y-2">
                    <div class="flex items-center gap-2">
                      <span class={[
                        "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
                        verdict_decision_classes(@session.verdict.decision)
                      ]}>
                        {@session.verdict.decision}
                      </span>
                      <span :if={@session.verdict.consensus_reached} class="text-xs text-success">
                        Consensus
                      </span>
                    </div>
                    <p :if={@session.verdict.confidence} class="text-xs text-base-content/50">
                      Confidence:
                      <span class="font-medium tabular-nums">
                        {Float.round(@session.verdict.confidence * 100, 1)}%
                      </span>
                    </p>
                    <p
                      :if={@session.verdict.reasoning}
                      class="text-xs text-base-content/70 bg-base-200/50 rounded-lg p-3"
                    >
                      {if @is_ephemeral? and is_nil(@session.verdict.reasoning),
                        do: "[WIPED]",
                        else: @session.verdict.reasoning}
                    </p>
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

            <%!-- Quick Info Card --%>
            <div class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden">
              <div class="px-5 py-3 border-b border-base-300/30">
                <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
                  Quick Info
                </h2>
              </div>
              <div class="p-5 space-y-3">
                <.detail_row label="Violations">
                  <span class="tabular-nums">{length(@violations)}</span>
                </.detail_row>
                <.detail_row label="Workspace">
                  {@current_workspace.name}
                </.detail_row>
              </div>
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
end
