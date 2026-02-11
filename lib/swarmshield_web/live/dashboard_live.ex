defmodule SwarmshieldWeb.DashboardLive do
  @moduledoc """
  Main security operations center dashboard.

  Shows real-time stats for events, agents, deliberations, and GhostProtocol
  ephemeral sessions. All data loaded via context functions with assign_async.
  PubSub subscriptions for real-time counter updates.
  """
  use SwarmshieldWeb, :live_view

  alias Phoenix.LiveView.AsyncResult
  alias Swarmshield.Deliberation
  alias Swarmshield.Gateway
  alias Swarmshield.GhostProtocol
  alias SwarmshieldWeb.Hooks.AuthHooks

  @impl true
  def mount(_params, _session, socket) do
    workspace_id = socket.assigns.current_workspace.id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "events:#{workspace_id}")
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberations:#{workspace_id}")
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "ghost_protocol:#{workspace_id}")
    end

    {:ok, assign(socket, :page_title, "Dashboard")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    # Permission check on every navigation
    if AuthHooks.has_socket_permission?(socket, "dashboard:view") do
      {:noreply, load_dashboard_stats(socket)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view the dashboard.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  # -------------------------------------------------------------------
  # Real-time PubSub handlers — increment counters without DB round-trip
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:event_created, _event}, socket) do
    {:noreply, increment_event_stat(socket)}
  end

  def handle_info({:violation_created, _violation}, socket) do
    {:noreply, socket}
  end

  def handle_info({:session_created, _session_id, _status}, socket) do
    {:noreply, increment_delib_stat(socket)}
  end

  def handle_info({:session_updated, _session_id, :completed}, socket) do
    {:noreply, increment_verdict_stat(socket)}
  end

  def handle_info({:session_updated, _session_id, _status}, socket) do
    {:noreply, socket}
  end

  def handle_info({:trigger_deliberation, _event_id, _workflow}, socket) do
    {:noreply, socket}
  end

  def handle_info({:config_created, _config_id}, socket) do
    {:noreply, reload_ghost_stats(socket)}
  end

  def handle_info({:config_updated, _config_id}, socket) do
    {:noreply, reload_ghost_stats(socket)}
  end

  def handle_info({:config_deleted, _config_id}, socket) do
    {:noreply, reload_ghost_stats(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private: data loading
  # -------------------------------------------------------------------

  defp load_dashboard_stats(socket) do
    workspace_id = socket.assigns.current_workspace.id

    assign_async(socket, [:event_stats, :delib_stats, :ghost_stats], fn ->
      {:ok,
       %{
         event_stats: Gateway.get_dashboard_stats(workspace_id),
         delib_stats: Deliberation.get_dashboard_stats(workspace_id),
         ghost_stats: GhostProtocol.get_dashboard_stats(workspace_id)
       }}
    end)
  end

  defp increment_event_stat(socket) do
    case socket.assigns do
      %{event_stats: %{ok?: true, result: stats}} ->
        updated = %{stats | total_events_24h: stats.total_events_24h + 1}
        assign(socket, :event_stats, AsyncResult.ok(updated))

      _ ->
        socket
    end
  end

  defp increment_delib_stat(socket) do
    case socket.assigns do
      %{delib_stats: %{ok?: true, result: stats}} ->
        updated = %{stats | active_deliberations: stats.active_deliberations + 1}
        assign(socket, :delib_stats, AsyncResult.ok(updated))

      _ ->
        socket
    end
  end

  defp increment_verdict_stat(socket) do
    case socket.assigns do
      %{delib_stats: %{ok?: true, result: stats}} ->
        updated = %{
          stats
          | verdicts_today: stats.verdicts_today + 1,
            active_deliberations: max(stats.active_deliberations - 1, 0)
        }

        assign(socket, :delib_stats, AsyncResult.ok(updated))

      _ ->
        socket
    end
  end

  defp reload_ghost_stats(socket) do
    workspace_id = socket.assigns.current_workspace.id

    assign_async(socket, :ghost_stats, fn ->
      {:ok, %{ghost_stats: GhostProtocol.get_dashboard_stats(workspace_id)}}
    end)
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
      active_nav={:dashboard}
    >
      <div class="space-y-8">
        <%!-- Page header --%>
        <div id="dashboard-header">
          <h1 class="text-2xl font-bold tracking-tight">Security Operations</h1>
          <p class="text-sm text-base-content/50 mt-1">
            Real-time monitoring for {@current_workspace.name}
          </p>
        </div>

        <%!-- Event Stats Section --%>
        <section id="event-stats-section" aria-label="Event statistics">
          <div class="flex items-center gap-2 mb-4">
            <div class="size-1.5 rounded-full bg-info animate-pulse" />
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
              Event Pipeline
            </h2>
            <span class="text-xs text-base-content/30">— last 24h</span>
          </div>

          <.async_result :let={stats} assign={@event_stats}>
            <:loading>
              <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
                <.stat_skeleton :for={_ <- 1..4} />
              </div>
            </:loading>
            <:failed :let={_reason}>
              <div class="rounded-xl border border-error/20 bg-error/5 p-6 text-center">
                <.icon name="hero-exclamation-triangle" class="size-6 text-error mx-auto mb-2" />
                <p class="text-sm text-error">Failed to load event statistics</p>
              </div>
            </:failed>

            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4" id="event-stats-grid">
              <.stat_card
                id="stat-total-events"
                label="Total Events"
                value={stats.total_events_24h}
                icon="hero-bolt"
                color="info"
                subtitle="24h window"
              />
              <.stat_card
                id="stat-flagged-events"
                label="Flagged"
                value={stats.flagged_events}
                icon="hero-flag"
                color="warning"
                subtitle="Needs review"
              />
              <.stat_card
                id="stat-blocked-events"
                label="Blocked"
                value={stats.blocked_events}
                icon="hero-shield-exclamation"
                color="error"
                subtitle="Threats stopped"
              />
              <.stat_card
                id="stat-active-agents"
                label="Active Agents"
                value={stats.active_agents}
                icon="hero-cpu-chip"
                color="success"
                subtitle="Monitored"
              />
            </div>
          </.async_result>
        </section>

        <%!-- Deliberation Stats Section --%>
        <section id="delib-stats-section" aria-label="Deliberation statistics">
          <div class="flex items-center gap-2 mb-4">
            <div class="size-1.5 rounded-full bg-primary animate-pulse" />
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
              Deliberation Engine
            </h2>
          </div>

          <.async_result :let={stats} assign={@delib_stats}>
            <:loading>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <.stat_skeleton :for={_ <- 1..2} />
              </div>
            </:loading>
            <:failed :let={_reason}>
              <div class="rounded-xl border border-error/20 bg-error/5 p-6 text-center">
                <p class="text-sm text-error">Failed to load deliberation statistics</p>
              </div>
            </:failed>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4" id="delib-stats-grid">
              <.stat_card
                id="stat-active-deliberations"
                label="Active Deliberations"
                value={stats.active_deliberations}
                icon="hero-chat-bubble-left-right"
                color="primary"
                subtitle="Agents debating"
              />
              <.stat_card
                id="stat-verdicts-today"
                label="Verdicts Today"
                value={stats.verdicts_today}
                icon="hero-scale"
                color="accent"
                subtitle="Consensus reached"
              />
            </div>
          </.async_result>
        </section>

        <%!-- GhostProtocol Stats Section --%>
        <section id="ghost-stats-section" aria-label="GhostProtocol statistics">
          <div class="flex items-center gap-2 mb-4">
            <div class="size-1.5 rounded-full bg-secondary" />
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
              GhostProtocol
            </h2>
            <span class="ml-auto inline-flex items-center gap-1 text-xs text-base-content/30">
              <.icon name="hero-eye-slash-solid" class="size-3" /> Ephemeral Security
            </span>
          </div>

          <.async_result :let={stats} assign={@ghost_stats}>
            <:loading>
              <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                <.stat_skeleton :for={_ <- 1..3} />
              </div>
            </:loading>
            <:failed :let={_reason}>
              <div class="rounded-xl border border-error/20 bg-error/5 p-6 text-center">
                <p class="text-sm text-error">Failed to load GhostProtocol statistics</p>
              </div>
            </:failed>

            <div
              class="grid grid-cols-1 sm:grid-cols-3 gap-4"
              id="ghost-stats-grid"
            >
              <.stat_card
                id="stat-active-ephemeral"
                label="Active Sessions"
                value={stats.active_ephemeral_sessions}
                icon="hero-eye-slash"
                color="secondary"
                subtitle="Ephemeral"
              />
              <.stat_card
                id="stat-sessions-wiped"
                label="Sessions Wiped"
                value={stats.total_sessions_wiped}
                icon="hero-trash"
                color="neutral"
                subtitle="Data destroyed"
              />
              <.stat_card
                id="stat-active-configs"
                label="Active Configs"
                value={stats.active_configs}
                icon="hero-cog-6-tooth"
                color="neutral"
                subtitle="Enabled"
              />
            </div>
          </.async_result>
        </section>

        <%!-- Quick Actions --%>
        <section id="quick-actions" aria-label="Quick actions">
          <div class="flex items-center gap-2 mb-4">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
              Quick Navigation
            </h2>
          </div>
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
            <.quick_link
              path={~p"/events"}
              icon="hero-bolt"
              label="View Events"
              description="Live event stream"
            />
            <.quick_link
              path={~p"/agents"}
              icon="hero-cpu-chip"
              label="Agent Registry"
              description="Monitored agents"
            />
            <.quick_link
              path={~p"/deliberations"}
              icon="hero-chat-bubble-left-right"
              label="Deliberations"
              description="AI debate sessions"
            />
            <.quick_link
              path={~p"/ghost-protocol"}
              icon="hero-eye-slash"
              label="GhostProtocol"
              description="Ephemeral sessions"
            />
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Components
  # -------------------------------------------------------------------

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true
  attr :color, :string, required: true
  attr :subtitle, :string, default: nil

  defp stat_card(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "group relative overflow-hidden rounded-xl border border-base-300/50",
        "bg-base-100 p-5 transition-all duration-200",
        "hover:border-#{@color}/30 hover:shadow-lg hover:shadow-#{@color}/5"
      ]}
    >
      <%!-- Subtle gradient accent at top --%>
      <div class={[
        "absolute inset-x-0 top-0 h-[2px]",
        color_gradient(@color)
      ]} />

      <div class="flex items-start justify-between">
        <div class="space-y-2">
          <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">
            {@label}
          </p>
          <p class={[
            "text-3xl font-bold tracking-tight tabular-nums",
            color_text(@color)
          ]}>
            {format_number(@value)}
          </p>
          <p :if={@subtitle} class="text-xs text-base-content/40">
            {@subtitle}
          </p>
        </div>
        <div class={[
          "flex items-center justify-center size-10 rounded-lg",
          color_bg(@color)
        ]}>
          <.icon name={@icon} class={["size-5", color_icon(@color)]} />
        </div>
      </div>
    </div>
    """
  end

  defp stat_skeleton(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300/50 bg-base-100 p-5 animate-pulse">
      <div class="flex items-start justify-between">
        <div class="space-y-3">
          <div class="h-3 w-20 rounded bg-base-300/50" />
          <div class="h-8 w-16 rounded bg-base-300/50" />
          <div class="h-3 w-14 rounded bg-base-300/30" />
        </div>
        <div class="size-10 rounded-lg bg-base-300/30" />
      </div>
    </div>
    """
  end

  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true

  defp quick_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class={[
        "group flex items-center gap-3 rounded-xl border border-base-300/50",
        "bg-base-100 px-4 py-3 transition-all duration-200",
        "hover:border-primary/30 hover:bg-base-200/50"
      ]}
    >
      <div class="flex items-center justify-center size-9 rounded-lg bg-base-200 group-hover:bg-primary/10 transition-colors">
        <.icon
          name={@icon}
          class="size-4 text-base-content/60 group-hover:text-primary transition-colors"
        />
      </div>
      <div>
        <p class="text-sm font-medium">{@label}</p>
        <p class="text-xs text-base-content/40">{@description}</p>
      </div>
      <.icon
        name="hero-chevron-right-mini"
        class="size-4 ml-auto text-base-content/20 group-hover:text-primary/60 transition-colors"
      />
    </.link>
    """
  end

  # -------------------------------------------------------------------
  # Color helpers (return Tailwind classes)
  # -------------------------------------------------------------------

  defp color_gradient("info"), do: "bg-gradient-to-r from-info/80 to-info/20"
  defp color_gradient("warning"), do: "bg-gradient-to-r from-warning/80 to-warning/20"
  defp color_gradient("error"), do: "bg-gradient-to-r from-error/80 to-error/20"
  defp color_gradient("success"), do: "bg-gradient-to-r from-success/80 to-success/20"
  defp color_gradient("primary"), do: "bg-gradient-to-r from-primary/80 to-primary/20"
  defp color_gradient("accent"), do: "bg-gradient-to-r from-accent/80 to-accent/20"
  defp color_gradient("secondary"), do: "bg-gradient-to-r from-secondary/80 to-secondary/20"
  defp color_gradient("neutral"), do: "bg-gradient-to-r from-neutral/80 to-neutral/20"
  defp color_gradient(_), do: "bg-gradient-to-r from-base-300 to-base-200"

  defp color_text("info"), do: "text-info"
  defp color_text("warning"), do: "text-warning"
  defp color_text("error"), do: "text-error"
  defp color_text("success"), do: "text-success"
  defp color_text("primary"), do: "text-primary"
  defp color_text("accent"), do: "text-accent"
  defp color_text("secondary"), do: "text-secondary"
  defp color_text(_), do: "text-base-content"

  defp color_bg("info"), do: "bg-info/10"
  defp color_bg("warning"), do: "bg-warning/10"
  defp color_bg("error"), do: "bg-error/10"
  defp color_bg("success"), do: "bg-success/10"
  defp color_bg("primary"), do: "bg-primary/10"
  defp color_bg("accent"), do: "bg-accent/10"
  defp color_bg("secondary"), do: "bg-secondary/10"
  defp color_bg(_), do: "bg-base-200"

  defp color_icon("info"), do: "text-info"
  defp color_icon("warning"), do: "text-warning"
  defp color_icon("error"), do: "text-error"
  defp color_icon("success"), do: "text-success"
  defp color_icon("primary"), do: "text-primary"
  defp color_icon("accent"), do: "text-accent"
  defp color_icon("secondary"), do: "text-secondary"
  defp color_icon(_), do: "text-base-content/60"

  defp format_number(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_number(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}K"
  end

  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(_), do: "0"
end
