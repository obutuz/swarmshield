defmodule SwarmshieldWeb.AgentShowLive do
  @moduledoc """
  Agent detail view showing configuration, recent events, and violation history.

  Displays agent metadata, real-time stats, recent events via streams,
  and linked policy violations. Subscribes to PubSub for real-time
  event updates scoped to this specific agent.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Gateway
  alias Swarmshield.Policies
  alias SwarmshieldWeb.Hooks.AuthHooks

  @events_page_size 50
  @violations_page_size 20

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agent Details")
     |> assign(:active_tab, "events")}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "agents:view") do
      {:noreply, load_agent(socket, id)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view agents.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in ["events", "violations"] do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_info({:event_created, event}, socket) do
    agent_id = socket.assigns.agent.id

    if event.registered_agent_id == agent_id do
      stats = Gateway.get_agent_stats(agent_id)

      {:noreply,
       socket
       |> stream_insert(:events, event, at: 0)
       |> assign(:stats, stats)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp load_agent(socket, id) do
    workspace_id = socket.assigns.current_workspace.id

    case Gateway.get_registered_agent_for_workspace(id, workspace_id) do
      nil ->
        socket
        |> put_flash(:error, "Agent not found.")
        |> redirect(to: ~p"/agents")

      agent ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Swarmshield.PubSub, "events:#{workspace_id}")
        end

        stats = Gateway.get_agent_stats(agent.id)

        {events, _event_count} =
          Gateway.list_agent_events(workspace_id,
            registered_agent_id: agent.id,
            page_size: @events_page_size
          )

        {violations, violations_count} =
          Policies.list_policy_violations(workspace_id,
            registered_agent_id: agent.id,
            page_size: @violations_page_size
          )

        socket
        |> assign(:agent, agent)
        |> assign(:stats, stats)
        |> assign(:violations_count, violations_count)
        |> stream(:events, events, reset: true)
        |> stream(:violations, violations, reset: true)
    end
  end

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
      active_nav={:agents}
    >
      <div class="space-y-6">
        <%!-- Back link + Header --%>
        <div id="agent-header">
          <.link
            navigate={~p"/agents"}
            class="inline-flex items-center gap-1 text-sm text-base-content/40 hover:text-base-content/60 transition-colors mb-4"
          >
            <.icon name="hero-arrow-left-mini" class="size-4" /> Back to Agents
          </.link>

          <div class="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4">
            <div class="flex items-start gap-4">
              <div class="flex items-center justify-center size-12 rounded-xl bg-primary/10 shrink-0">
                <.icon name="hero-cpu-chip" class="size-6 text-primary" />
              </div>
              <div>
                <h1 class="text-2xl font-bold tracking-tight">{@agent.name}</h1>
                <p :if={@agent.description} class="text-sm text-base-content/50 mt-1 max-w-xl">
                  {@agent.description}
                </p>
              </div>
            </div>
            <div class="flex items-center gap-2">
              <.agent_status_badge status={@agent.status} />
              <.risk_badge level={@agent.risk_level} />
            </div>
          </div>
        </div>

        <%!-- Agent Info Cards --%>
        <div id="agent-info" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
            <p class="text-xs font-medium text-base-content/40 uppercase tracking-wider">Type</p>
            <p class="text-lg font-semibold mt-1">{format_agent_type(@agent.agent_type)}</p>
          </div>
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
            <p class="text-xs font-medium text-base-content/40 uppercase tracking-wider">API Key</p>
            <p class="text-lg font-mono font-semibold mt-1">{@agent.api_key_prefix}••••••••</p>
          </div>
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
            <p class="text-xs font-medium text-base-content/40 uppercase tracking-wider">Last Seen</p>
            <p class="text-lg font-semibold mt-1">{format_relative_time(@agent.last_seen_at)}</p>
          </div>
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
            <p class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
              Registered
            </p>
            <p class="text-lg font-semibold mt-1">
              {Calendar.strftime(@agent.inserted_at, "%b %d, %Y")}
            </p>
          </div>
        </div>

        <%!-- Stats Row --%>
        <div id="agent-stats" class="grid grid-cols-3 gap-4">
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4 text-center">
            <p class="text-2xl font-bold tabular-nums">{@stats.total_events}</p>
            <p class="text-xs text-base-content/40 mt-1">Total Events</p>
          </div>
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4 text-center">
            <p class="text-2xl font-bold tabular-nums text-warning">{@stats.flagged_count}</p>
            <p class="text-xs text-base-content/40 mt-1">Flagged</p>
          </div>
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4 text-center">
            <p class="text-2xl font-bold tabular-nums text-error">{@stats.blocked_count}</p>
            <p class="text-xs text-base-content/40 mt-1">Blocked</p>
          </div>
        </div>

        <%!-- Metadata --%>
        <div
          :if={@agent.metadata != %{}}
          id="agent-metadata"
          class="rounded-xl border border-base-300/50 bg-base-100 p-4"
        >
          <h3 class="text-sm font-medium text-base-content/50 mb-3">Metadata</h3>
          <pre class="text-xs bg-base-200/50 rounded-lg p-3 overflow-x-auto"><code>{Jason.encode!(@agent.metadata, pretty: true)}</code></pre>
        </div>

        <%!-- Tab Navigation --%>
        <div class="border-b border-base-300/50">
          <nav class="flex gap-6" aria-label="Tabs">
            <button
              phx-click="switch_tab"
              phx-value-tab="events"
              class={[
                "pb-3 text-sm font-medium border-b-2 transition-colors",
                if(@active_tab == "events",
                  do: "border-primary text-primary",
                  else: "border-transparent text-base-content/40 hover:text-base-content/60"
                )
              ]}
            >
              <.icon name="hero-bolt" class="size-4 mr-1.5 inline-block" /> Recent Events
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="violations"
              class={[
                "pb-3 text-sm font-medium border-b-2 transition-colors",
                if(@active_tab == "violations",
                  do: "border-primary text-primary",
                  else: "border-transparent text-base-content/40 hover:text-base-content/60"
                )
              ]}
            >
              <.icon name="hero-shield-exclamation" class="size-4 mr-1.5 inline-block" /> Violations
              <span
                :if={@violations_count > 0}
                class="ml-1.5 px-1.5 py-0.5 rounded-full text-xs bg-error/10 text-error tabular-nums"
              >
                {@violations_count}
              </span>
            </button>
          </nav>
        </div>

        <%!-- Events Tab --%>
        <div :if={@active_tab == "events"} id="events-tab">
          <div class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden">
            <div class="overflow-x-auto">
              <table class="table table-sm" id="agent-events-table">
                <thead>
                  <tr class="border-b border-base-300/50">
                    <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                      Content
                    </th>
                    <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                      Type
                    </th>
                    <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                      Status
                    </th>
                    <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                      Severity
                    </th>
                    <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                      Time
                    </th>
                    <th class="w-10"></th>
                  </tr>
                </thead>
                <tbody id="agent-events-stream" phx-update="stream">
                  <tr
                    :for={{dom_id, event} <- @streams.events}
                    id={dom_id}
                    class="border-b border-base-300/30 hover:bg-base-200/50 transition-colors cursor-pointer"
                    phx-click={JS.navigate(~p"/events/#{event.id}")}
                  >
                    <td class="max-w-xs">
                      <p class="text-sm truncate">{event.content}</p>
                    </td>
                    <td>
                      <span class="badge badge-ghost badge-sm">{event.event_type}</span>
                    </td>
                    <td>
                      <.event_status_badge status={event.status} />
                    </td>
                    <td>
                      <.severity_badge severity={event.severity} />
                    </td>
                    <td>
                      <span class="text-xs text-base-content/50">
                        {format_relative_time(event.inserted_at)}
                      </span>
                    </td>
                    <td>
                      <.icon name="hero-chevron-right-mini" class="size-4 text-base-content/20" />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div :if={@stats.total_events == 0} id="events-empty" class="p-12 text-center">
              <.icon name="hero-bolt" class="size-12 text-base-content/20 mx-auto mb-4" />
              <p class="text-base-content/50 font-medium">No events recorded</p>
              <p class="text-sm text-base-content/30 mt-1">
                Events will appear here when this agent sends data through the API gateway.
              </p>
            </div>
          </div>
        </div>

        <%!-- Violations Tab --%>
        <div :if={@active_tab == "violations"} id="violations-tab">
          <div class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden">
            <div class="overflow-x-auto">
              <table class="table table-sm" id="agent-violations-table">
                <thead>
                  <tr class="border-b border-base-300/50">
                    <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                      Rule
                    </th>
                    <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                      Action
                    </th>
                    <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                      Severity
                    </th>
                    <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                      Resolved
                    </th>
                    <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                      Time
                    </th>
                    <th class="w-10"></th>
                  </tr>
                </thead>
                <tbody id="agent-violations-stream" phx-update="stream">
                  <tr
                    :for={{dom_id, violation} <- @streams.violations}
                    id={dom_id}
                    class="border-b border-base-300/30 hover:bg-base-200/50 transition-colors cursor-pointer"
                    phx-click={JS.navigate(~p"/events/#{violation.agent_event_id}")}
                  >
                    <td>
                      <p class="text-sm font-medium">{violation.policy_rule.name}</p>
                    </td>
                    <td>
                      <.violation_action_badge action={violation.action_taken} />
                    </td>
                    <td>
                      <.severity_badge severity={violation.severity} />
                    </td>
                    <td>
                      <span :if={violation.resolved} class="badge badge-success badge-sm gap-1">
                        <.icon name="hero-check-mini" class="size-3" /> Resolved
                      </span>
                      <span :if={!violation.resolved} class="badge badge-ghost badge-sm">
                        Open
                      </span>
                    </td>
                    <td>
                      <span class="text-xs text-base-content/50">
                        {format_relative_time(violation.inserted_at)}
                      </span>
                    </td>
                    <td>
                      <.icon name="hero-chevron-right-mini" class="size-4 text-base-content/20" />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div :if={@violations_count == 0} id="violations-empty" class="p-12 text-center">
              <.icon name="hero-shield-check" class="size-12 text-success/30 mx-auto mb-4" />
              <p class="text-base-content/50 font-medium">No policy violations</p>
              <p class="text-sm text-base-content/30 mt-1">
                This agent has not triggered any policy rules.
              </p>
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

  defp agent_status_badge(%{status: :active} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-success/10 text-success">
      <span class="size-1.5 rounded-full bg-success" /> Active
    </span>
    """
  end

  defp agent_status_badge(%{status: :suspended} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-warning/10 text-warning">
      <span class="size-1.5 rounded-full bg-warning" /> Suspended
    </span>
    """
  end

  defp agent_status_badge(%{status: :revoked} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium bg-error/10 text-error">
      <span class="size-1.5 rounded-full bg-error" /> Revoked
    </span>
    """
  end

  defp agent_status_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-sm">{@status}</span>
    """
  end

  attr :level, :atom, required: true

  defp risk_badge(%{level: :critical} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-1 rounded-full text-xs font-bold bg-error/10 text-error">
      CRITICAL
    </span>
    """
  end

  defp risk_badge(%{level: :high} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium bg-error/10 text-error/80">
      HIGH
    </span>
    """
  end

  defp risk_badge(%{level: :medium} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium bg-warning/10 text-warning">
      MEDIUM
    </span>
    """
  end

  defp risk_badge(%{level: :low} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-1 rounded-full text-xs font-medium bg-success/10 text-success">
      LOW
    </span>
    """
  end

  defp risk_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-sm">{@level}</span>
    """
  end

  attr :status, :atom, required: true

  defp event_status_badge(%{status: :allowed} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-success/10 text-success">
      <span class="size-1.5 rounded-full bg-success" /> Allowed
    </span>
    """
  end

  defp event_status_badge(%{status: :flagged} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-warning/10 text-warning">
      <span class="size-1.5 rounded-full bg-warning" /> Flagged
    </span>
    """
  end

  defp event_status_badge(%{status: :blocked} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-error/10 text-error">
      <span class="size-1.5 rounded-full bg-error" /> Blocked
    </span>
    """
  end

  defp event_status_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-sm">{@status}</span>
    """
  end

  attr :severity, :atom, required: true

  defp severity_badge(%{severity: :critical} = assigns) do
    ~H"""
    <span class="text-xs font-bold text-error">Critical</span>
    """
  end

  defp severity_badge(%{severity: :warning} = assigns) do
    ~H"""
    <span class="text-xs font-medium text-warning">Warning</span>
    """
  end

  defp severity_badge(%{severity: :info} = assigns) do
    ~H"""
    <span class="text-xs text-base-content/50">Info</span>
    """
  end

  defp severity_badge(assigns) do
    ~H"""
    <span class="text-xs text-base-content/40">{@severity}</span>
    """
  end

  attr :action, :atom, required: true

  defp violation_action_badge(%{action: :blocked} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-error/10 text-error">
      Blocked
    </span>
    """
  end

  defp violation_action_badge(%{action: :flagged} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-warning/10 text-warning">
      Flagged
    </span>
    """
  end

  defp violation_action_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-sm">{@action}</span>
    """
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp format_agent_type(:autonomous), do: "Autonomous"
  defp format_agent_type(:semi_autonomous), do: "Semi-Autonomous"
  defp format_agent_type(:tool_agent), do: "Tool Agent"
  defp format_agent_type(:chatbot), do: "Chatbot"
  defp format_agent_type(type), do: type |> to_string() |> String.capitalize()

  defp format_relative_time(nil), do: "Never"

  defp format_relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(:second), dt, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %d, %Y")
    end
  end

  defp format_relative_time(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_relative_time()
  end
end
