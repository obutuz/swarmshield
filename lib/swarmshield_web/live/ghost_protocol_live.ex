defmodule SwarmshieldWeb.GhostProtocolLive do
  @moduledoc """
  GhostProtocol operations dashboard.

  Shows active ephemeral sessions with real-time countdown timers,
  wipe history for completed sessions, and aggregate stats.
  Subscribes to PubSub for real-time session and wipe events.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.{Deliberation, GhostProtocol}
  alias SwarmshieldWeb.Hooks.AuthHooks

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "GhostProtocol")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "ghost_protocol:view") do
      {:noreply, load_data(socket)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view GhostProtocol.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  @impl true
  def handle_info({:session_created, session_id, _status}, socket) do
    reload_if_ephemeral(socket, session_id)
  end

  def handle_info({:session_updated, session_id, _status}, socket) do
    reload_if_ephemeral(socket, session_id)
  end

  def handle_info({:wipe_completed, _session_id}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info({:wipe_started, _session_id}, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info({event, _config_id}, socket)
      when event in [:config_created, :config_updated, :config_deleted] do
    {:noreply, load_data(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp load_data(socket) do
    workspace_id = socket.assigns.current_workspace.id

    if connected?(socket) do
      GhostProtocol.subscribe_to_workspace(workspace_id)
      Deliberation.subscribe_to_workspace_deliberations(workspace_id)
    end

    stats = GhostProtocol.get_dashboard_stats(workspace_id)
    active_sessions = GhostProtocol.list_active_ephemeral_sessions(workspace_id)
    history = GhostProtocol.list_completed_ephemeral_sessions(workspace_id)

    socket
    |> assign(:stats, stats)
    |> stream(:active_sessions, active_sessions, reset: true)
    |> stream(:history, history, reset: true)
  end

  defp reload_if_ephemeral(socket, session_id) do
    case GhostProtocol.get_session_with_ghost_config(session_id) do
      %{workflow: %{ghost_protocol_config_id: gpc_id}} when not is_nil(gpc_id) ->
        {:noreply, load_data(socket)}

      _ ->
        {:noreply, socket}
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
      active_nav={:ghost_protocol}
    >
      <div class="space-y-6">
        <%!-- Header --%>
        <div id="gp-header">
          <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
            <div>
              <h1 class="text-2xl font-bold tracking-tight">
                <.icon name="hero-eye-slash" class="size-7 inline-block mr-1 text-secondary" />
                GhostProtocol
              </h1>
              <p class="text-sm text-base-content/50 mt-1">
                Ephemeral session management &middot; Agents work then vanish
              </p>
            </div>
          </div>
        </div>

        <%!-- Stats Cards --%>
        <div id="gp-stats" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
          <div class="rounded-xl border border-secondary/30 bg-secondary/5 p-4">
            <div class="flex items-center justify-between mb-2">
              <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                Active Sessions
              </span>
              <.icon name="hero-bolt" class="size-5 text-secondary" />
            </div>
            <p class="text-2xl font-bold tabular-nums">{@stats.active_ephemeral_sessions}</p>
          </div>
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
            <div class="flex items-center justify-between mb-2">
              <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                Sessions Wiped
              </span>
              <.icon name="hero-trash" class="size-5 text-error" />
            </div>
            <p class="text-2xl font-bold tabular-nums">{@stats.total_sessions_wiped}</p>
          </div>
          <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
            <div class="flex items-center justify-between mb-2">
              <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                Active Configs
              </span>
              <.icon name="hero-cog-6-tooth" class="size-5 text-primary" />
            </div>
            <p class="text-2xl font-bold tabular-nums">{@stats.active_configs}</p>
          </div>
        </div>

        <%!-- Active Ephemeral Sessions --%>
        <div id="active-sessions-section" class="rounded-xl border border-base-300/50 bg-base-100">
          <div class="p-4 border-b border-base-300/30">
            <h2 class="text-sm font-medium flex items-center gap-2">
              <.icon name="hero-bolt" class="size-4 text-secondary" /> Active Ephemeral Sessions
            </h2>
          </div>
          <div class="divide-y divide-base-300/30">
            <div id="active-sessions-stream" phx-update="stream">
              <div
                :for={{dom_id, session} <- @streams.active_sessions}
                id={dom_id}
                class="p-4 hover:bg-base-200/30 transition-colors"
              >
                <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
                  <div class="flex items-center gap-3 min-w-0">
                    <div class="flex items-center justify-center size-8 rounded-lg bg-secondary/10 shrink-0">
                      <.icon name="hero-eye-slash" class="size-4 text-secondary" />
                    </div>
                    <div class="min-w-0">
                      <.link
                        navigate={~p"/ghost-protocol/#{session.id}"}
                        class="text-sm font-medium hover:text-primary transition-colors truncate block"
                      >
                        {workflow_name(session)}
                      </.link>
                      <p class="text-xs text-base-content/40 font-mono truncate">
                        {String.slice(session.id, 0, 8)}...
                      </p>
                    </div>
                  </div>
                  <div class="flex items-center gap-3 shrink-0">
                    <.session_phase_badge status={session.status} />
                    <div :if={session.expires_at} class="text-right">
                      <p class="text-[10px] text-base-content/30 uppercase">Expires</p>
                      <p class={[
                        "text-xs font-mono tabular-nums",
                        if(expired?(session.expires_at),
                          do: "text-error font-bold",
                          else: "text-base-content/60"
                        )
                      ]}>
                        {format_remaining(session.expires_at)}
                      </p>
                    </div>
                    <div class="text-right">
                      <p class="text-[10px] text-base-content/30 uppercase">Strategy</p>
                      <p class="text-xs font-medium">
                        {session.workflow.ghost_protocol_config.wipe_strategy}
                      </p>
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <div
              id="active-sessions-empty"
              class="hidden only:block p-8 text-center"
            >
              <.icon name="hero-eye-slash" class="size-8 text-base-content/20 mx-auto mb-2" />
              <p class="text-sm text-base-content/40">No active ghost sessions</p>
              <p class="text-xs text-base-content/30 mt-1">
                Ephemeral sessions appear here when triggered
              </p>
            </div>
          </div>
        </div>

        <%!-- Wipe History --%>
        <div id="wipe-history-section" class="rounded-xl border border-base-300/50 bg-base-100">
          <div class="p-4 border-b border-base-300/30">
            <h2 class="text-sm font-medium flex items-center gap-2">
              <.icon name="hero-trash" class="size-4 text-error" /> Wipe History
            </h2>
          </div>
          <div class="divide-y divide-base-300/30">
            <div id="history-stream" phx-update="stream">
              <div
                :for={{dom_id, session} <- @streams.history}
                id={dom_id}
                class="p-4 hover:bg-base-200/30 transition-colors"
              >
                <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
                  <div class="flex items-center gap-3 min-w-0">
                    <div class={[
                      "flex items-center justify-center size-8 rounded-lg shrink-0",
                      wipe_status_bg(session.status)
                    ]}>
                      <.icon name={wipe_status_icon(session.status)} class="size-4" />
                    </div>
                    <div class="min-w-0">
                      <.link
                        navigate={~p"/deliberations/#{session.id}"}
                        class="text-sm font-medium hover:text-primary transition-colors truncate block"
                      >
                        {workflow_name(session)}
                      </.link>
                      <p class="text-xs text-base-content/40">
                        {format_datetime(session.completed_at || session.inserted_at)}
                      </p>
                    </div>
                  </div>
                  <div class="flex items-center gap-4 shrink-0">
                    <div class="text-right">
                      <p class="text-[10px] text-base-content/30 uppercase">Strategy</p>
                      <p class="text-xs font-medium">
                        {session.workflow.ghost_protocol_config.wipe_strategy}
                      </p>
                    </div>
                    <div :if={session.workflow.ghost_protocol_config.crypto_shred} class="text-right">
                      <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-[10px] font-medium bg-error/10 text-error">
                        <.icon name="hero-lock-closed" class="size-3" /> Shred
                      </span>
                    </div>
                    <div class="text-right">
                      <p class="text-[10px] text-base-content/30 uppercase">Duration</p>
                      <p class="text-xs tabular-nums">{format_session_duration(session)}</p>
                    </div>
                    <.wipe_result_badge status={session.status} />
                  </div>
                </div>
              </div>
            </div>

            <div
              id="history-empty"
              class="hidden only:block p-8 text-center"
            >
              <.icon name="hero-trash" class="size-8 text-base-content/20 mx-auto mb-2" />
              <p class="text-sm text-base-content/40">No wipe history</p>
              <p class="text-xs text-base-content/30 mt-1">
                Completed ephemeral sessions will appear here
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

  defp session_phase_badge(%{status: :pending} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-base-300/30 text-base-content/60">
      <.icon name="hero-clock" class="size-3" /> Pending
    </span>
    """
  end

  defp session_phase_badge(%{status: :analyzing} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-info/10 text-info">
      <.icon name="hero-magnifying-glass" class="size-3 animate-pulse" /> Analyzing
    </span>
    """
  end

  defp session_phase_badge(%{status: :deliberating} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-primary/10 text-primary">
      <.icon name="hero-chat-bubble-left-right" class="size-3" /> Deliberating
    </span>
    """
  end

  defp session_phase_badge(%{status: :voting} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-accent/10 text-accent">
      <.icon name="hero-hand-raised" class="size-3" /> Voting
    </span>
    """
  end

  defp session_phase_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-xs">{@status}</span>
    """
  end

  attr :status, :atom, required: true

  defp wipe_result_badge(%{status: :completed} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-success/10 text-success">
      <.icon name="hero-check-circle" class="size-3" /> Wiped
    </span>
    """
  end

  defp wipe_result_badge(%{status: :failed} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-error/10 text-error">
      <.icon name="hero-x-circle" class="size-3" /> Failed
    </span>
    """
  end

  defp wipe_result_badge(%{status: :timed_out} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-warning/10 text-warning">
      <.icon name="hero-clock" class="size-3" /> Timed Out
    </span>
    """
  end

  defp wipe_result_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-xs">{@status}</span>
    """
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp workflow_name(%{workflow: %{name: name}}) when is_binary(name), do: name
  defp workflow_name(_session), do: "Unknown Workflow"

  defp expired?(nil), do: false

  defp expired?(%DateTime{} = expires_at) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end

  defp format_remaining(nil), do: "—"

  defp format_remaining(%DateTime{} = expires_at) do
    diff = DateTime.diff(expires_at, DateTime.utc_now(), :second)

    cond do
      diff <= 0 -> "EXPIRED"
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
    end
  end

  defp format_session_duration(%{started_at: nil}), do: "—"
  defp format_session_duration(%{started_at: _, completed_at: nil}), do: "—"

  defp format_session_duration(%{started_at: started, completed_at: completed}) do
    diff = DateTime.diff(completed, started, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
    end
  end

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt),
    do: Calendar.strftime(dt, "%b %d, %H:%M UTC")

  defp format_datetime(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> format_datetime()

  defp wipe_status_bg(:completed), do: "bg-success/10"
  defp wipe_status_bg(:failed), do: "bg-error/10"
  defp wipe_status_bg(:timed_out), do: "bg-warning/10"
  defp wipe_status_bg(_), do: "bg-base-300/30"

  defp wipe_status_icon(:completed), do: "hero-check-circle"
  defp wipe_status_icon(:failed), do: "hero-x-circle"
  defp wipe_status_icon(:timed_out), do: "hero-clock"
  defp wipe_status_icon(_), do: "hero-question-mark-circle"
end
