defmodule SwarmshieldWeb.GhostProtocolSessionLive do
  @moduledoc """
  Detailed lifecycle view for a single GhostProtocol ephemeral session.

  Shows the full lifecycle timeline (spawn -> analyze -> debate -> verdict -> wipe -> dead),
  agent status cards, countdown to expiry, wipe details, surviving artifacts (verdict),
  and linked ghost_protocol_config settings. PubSub for real-time lifecycle updates.
  """
  use SwarmshieldWeb, :live_view

  import SwarmshieldWeb.LiveHelpers, only: [ephemeral?: 1]

  alias Swarmshield.{Deliberation, GhostProtocol}
  alias SwarmshieldWeb.Hooks.AuthHooks

  @lifecycle_phases [:pending, :analyzing, :deliberating, :voting, :completed, :wiped]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "GhostProtocol Session")}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "ghost_protocol:view") do
      {:noreply, load_session(socket, id)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view GhostProtocol.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  @impl true
  def handle_info({:session_updated, _session_id, new_status}, socket)
      when new_status in [:completed, :failed, :timed_out] do
    {:noreply, reload_session(socket)}
  end

  def handle_info({:session_updated, _session_id, new_status}, socket) do
    {:noreply, assign(socket, :session, %{socket.assigns.session | status: new_status})}
  end

  def handle_info({:session_created, _session_id, _new_status}, socket) do
    {:noreply, reload_session(socket)}
  end

  def handle_info({:verdict_reached, _verdict_id, _decision}, socket) do
    {:noreply, reload_session(socket)}
  end

  def handle_info({:wipe_completed, _session_id}, socket) do
    {:noreply, reload_session(socket)}
  end

  def handle_info({:message_created, _message_id, _type}, socket) do
    {:noreply, reload_session(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp reload_session(socket) do
    session_id = socket.assigns.session.id
    ws_id = socket.assigns.current_workspace.id

    case Deliberation.get_full_session_for_workspace(session_id, ws_id) do
      nil -> socket
      session -> apply_session_assigns(socket, session)
    end
  end

  defp load_session(socket, id, workspace_id \\ nil) do
    ws_id = workspace_id || socket.assigns.current_workspace.id

    id
    |> Deliberation.get_full_session_for_workspace(ws_id)
    |> apply_session(socket)
  end

  defp apply_session(nil, socket) do
    socket
    |> put_flash(:error, "Session not found.")
    |> redirect(to: ~p"/ghost-protocol")
  end

  defp apply_session(session, socket) when not is_nil(session) do
    if ephemeral?(session) do
      mount_ephemeral_session(socket, session)
    else
      socket
      |> put_flash(:info, "This is not an ephemeral session.")
      |> redirect(to: ~p"/deliberations/#{session.id}")
    end
  end

  defp mount_ephemeral_session(socket, session) do
    if connected?(socket) do
      Deliberation.subscribe_to_session(session.id)
      GhostProtocol.subscribe_to_session(session.id)
    end

    socket
    |> apply_session_assigns(session)
    |> assign(:lifecycle_phases, @lifecycle_phases)
  end

  defp apply_session_assigns(socket, session) do
    config = session.workflow.ghost_protocol_config

    socket
    |> assign(:session, session)
    |> assign(:config, config)
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
        <%!-- Back link + Header --%>
        <div id="gp-session-header">
          <.link
            navigate={~p"/ghost-protocol"}
            class="inline-flex items-center gap-1 text-sm text-base-content/40 hover:text-base-content/60 transition-colors mb-4"
          >
            <.icon name="hero-arrow-left-mini" class="size-4" /> Back to GhostProtocol
          </.link>

          <div class="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4">
            <div>
              <h1 class="text-2xl font-bold tracking-tight">
                <.icon name="hero-eye-slash" class="size-6 inline-block mr-1 text-secondary" />
                Ephemeral Session
              </h1>
              <p class="text-sm text-base-content/50 mt-1 font-mono">
                {String.slice(@session.id, 0, 8)}...
              </p>
            </div>
            <.session_status_badge status={@session.status} />
          </div>
        </div>

        <%!-- Lifecycle Timeline --%>
        <div id="lifecycle-timeline" class="rounded-xl border border-secondary/30 bg-secondary/5 p-4">
          <h3 class="text-sm font-medium text-secondary mb-4">
            <.icon name="hero-arrow-right-circle" class="size-4 inline-block mr-1" />
            Session Lifecycle
          </h3>
          <div class="flex items-center gap-1 overflow-x-auto pb-2">
            <div
              :for={phase <- @lifecycle_phases}
              class={[
                "flex items-center gap-1.5 px-3 py-2 rounded-lg text-xs font-medium whitespace-nowrap transition-all",
                phase_classes(phase, @session.status)
              ]}
            >
              <.icon
                name={phase_icon(phase)}
                class={[
                  "size-3.5",
                  if(phase == current_phase(@session.status), do: "animate-pulse", else: "")
                ]}
              />
              {format_phase(phase)}
            </div>
            <.icon
              :if={phase_index(@session.status) < length(@lifecycle_phases) - 1}
              name="hero-chevron-right-mini"
              class="size-4 text-base-content/20 shrink-0"
            />
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
          <%!-- Main Column --%>
          <div class="lg:col-span-2 space-y-6">
            <%!-- Info Cards --%>
            <div id="session-info" class="grid grid-cols-2 sm:grid-cols-3 gap-4">
              <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
                <p class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                  Started
                </p>
                <p class="text-sm font-semibold mt-1">{format_datetime(@session.started_at)}</p>
              </div>
              <div class="rounded-xl border border-base-300/50 bg-base-100 p-4">
                <p class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                  Duration
                </p>
                <p class="text-sm font-semibold mt-1">{format_duration(@session)}</p>
              </div>
              <div
                :if={@session.expires_at}
                class="rounded-xl border border-base-300/50 bg-base-100 p-4"
              >
                <p class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                  Expires
                </p>
                <p class={[
                  "text-sm font-semibold mt-1 font-mono tabular-nums",
                  if(expired?(@session.expires_at),
                    do: "text-error",
                    else: "text-base-content"
                  )
                ]}>
                  {format_remaining(@session.expires_at)}
                </p>
              </div>
            </div>

            <%!-- Agent Status Cards --%>
            <div id="agent-cards">
              <h3 class="text-sm font-medium text-base-content/50 mb-3">
                <.icon name="hero-user-group" class="size-4 inline-block mr-1" />
                Agent Instances ({length(@session.agent_instances)})
              </h3>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div
                  :for={instance <- @session.agent_instances}
                  class={[
                    "rounded-xl border p-4",
                    if(instance.terminated_at,
                      do: "border-error/30 bg-error/5",
                      else: "border-base-300/50 bg-base-100"
                    )
                  ]}
                >
                  <div class="flex items-center gap-3 mb-2">
                    <div class={[
                      "flex items-center justify-center size-8 rounded-lg shrink-0",
                      if(instance.terminated_at, do: "bg-error/10", else: "bg-primary/10")
                    ]}>
                      <.icon
                        name={if(instance.terminated_at, do: "hero-x-mark", else: "hero-user-circle")}
                        class={[
                          "size-5",
                          if(instance.terminated_at, do: "text-error", else: "text-primary")
                        ]}
                      />
                    </div>
                    <div class="min-w-0">
                      <p class="text-sm font-medium truncate">{instance.agent_definition.name}</p>
                      <p class="text-xs text-base-content/40">{instance.role}</p>
                    </div>
                  </div>
                  <div class="space-y-1.5 text-xs">
                    <div class="flex justify-between">
                      <span class="text-base-content/40">Status</span>
                      <span class="font-medium">{instance.status}</span>
                    </div>
                    <div :if={instance.vote} class="flex justify-between">
                      <span class="text-base-content/40">Vote</span>
                      <span class={["font-medium", vote_color(instance.vote)]}>{instance.vote}</span>
                    </div>
                    <div :if={instance.confidence} class="flex justify-between">
                      <span class="text-base-content/40">Confidence</span>
                      <span class="font-medium tabular-nums">
                        {Float.round(instance.confidence * 100, 1)}%
                      </span>
                    </div>
                    <div :if={instance.terminated_at} class="flex justify-between">
                      <span class="text-error/60">Terminated</span>
                      <span class="text-error font-mono tabular-nums text-[11px]">
                        {Calendar.strftime(instance.terminated_at, "%H:%M:%S")}
                      </span>
                    </div>
                  </div>
                </div>
              </div>
              <div
                :if={Enum.empty?(@session.agent_instances)}
                class="py-6 text-center"
              >
                <p class="text-sm text-base-content/40">No agents spawned yet</p>
              </div>
            </div>
          </div>

          <%!-- Sidebar --%>
          <div class="space-y-6">
            <%!-- Surviving Artifacts: Verdict --%>
            <div
              :if={@session.verdict}
              id="surviving-verdict"
              class="rounded-xl border-2 border-success/40 bg-success/5 p-4"
            >
              <h3 class="text-sm font-medium text-success mb-3">
                <.icon name="hero-shield-check" class="size-4 inline-block mr-1" />
                Surviving Artifact: Verdict
              </h3>
              <div class="space-y-3">
                <div class="flex items-center gap-3">
                  <.verdict_badge decision={@session.verdict.decision} />
                  <span class="text-sm tabular-nums font-medium">
                    {Float.round(@session.verdict.confidence * 100, 1)}%
                  </span>
                </div>
                <p class="text-xs text-base-content/60">{@session.verdict.reasoning}</p>
                <div :if={@session.verdict.consensus_reached}>
                  <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-success/10 text-success">
                    <.icon name="hero-check-circle" class="size-3" /> Consensus
                  </span>
                </div>
              </div>
            </div>

            <div
              :if={!@session.verdict}
              id="no-verdict"
              class="rounded-xl border border-base-300/50 bg-base-100 p-4 text-center"
            >
              <.icon name="hero-scale" class="size-8 text-base-content/20 mx-auto mb-2" />
              <p class="text-sm text-base-content/40">Verdict pending</p>
            </div>

            <%!-- Config Details --%>
            <div id="config-details" class="rounded-xl border border-secondary/30 bg-secondary/5 p-4">
              <h3 class="text-sm font-medium text-secondary mb-3">
                <.icon name="hero-cog-6-tooth" class="size-4 inline-block mr-1" />
                GhostProtocol Config
              </h3>
              <div class="space-y-2 text-xs">
                <div class="flex justify-between">
                  <span class="text-base-content/40">Name</span>
                  <span class="font-medium">{@config.name}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-base-content/40">Wipe Strategy</span>
                  <span class="font-medium">{@config.wipe_strategy}</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-base-content/40">Max Duration</span>
                  <span class="font-medium tabular-nums">
                    {@config.max_session_duration_seconds}s
                  </span>
                </div>
                <div :if={@config.wipe_delay_seconds > 0} class="flex justify-between">
                  <span class="text-base-content/40">Wipe Delay</span>
                  <span class="font-medium tabular-nums">{@config.wipe_delay_seconds}s</span>
                </div>
                <div class="flex justify-between">
                  <span class="text-base-content/40">Crypto Shred</span>
                  <span class={[
                    "font-medium",
                    if(@config.crypto_shred, do: "text-error", else: "text-base-content/60")
                  ]}>
                    {if @config.crypto_shred, do: "Enabled", else: "Disabled"}
                  </span>
                </div>
                <div class="flex justify-between">
                  <span class="text-base-content/40">Auto Terminate</span>
                  <span class="font-medium">
                    {if @config.auto_terminate_on_expiry, do: "Yes", else: "No"}
                  </span>
                </div>
                <div :if={@config.wipe_fields != []} class="pt-1 border-t border-secondary/20">
                  <p class="text-base-content/40 mb-1">Wipe Fields</p>
                  <div class="flex flex-wrap gap-1">
                    <span
                      :for={field <- @config.wipe_fields}
                      class="px-1.5 py-0.5 rounded text-[10px] font-mono bg-secondary/10 text-secondary"
                    >
                      {field}
                    </span>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Error Display --%>
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

  defp verdict_badge(%{decision: :block} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-bold bg-error/10 text-error">
      Block
    </span>
    """
  end

  defp verdict_badge(%{decision: :flag} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-bold bg-warning/10 text-warning">
      Flag
    </span>
    """
  end

  defp verdict_badge(%{decision: :allow} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-bold bg-success/10 text-success">
      Allow
    </span>
    """
  end

  defp verdict_badge(%{decision: :escalate} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-3 py-1 rounded-full text-sm font-bold bg-primary/10 text-primary">
      Escalate
    </span>
    """
  end

  defp verdict_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost">{@decision}</span>
    """
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp current_phase(:completed), do: :completed
  defp current_phase(:failed), do: :completed
  defp current_phase(:timed_out), do: :completed
  defp current_phase(status), do: status

  defp phase_index(status) do
    idx = Enum.find_index(@lifecycle_phases, &(&1 == current_phase(status)))
    idx || 0
  end

  defp phase_classes(phase, current_status) do
    current_idx = phase_index(current_status)
    phase_idx = Enum.find_index(@lifecycle_phases, &(&1 == phase)) || 0

    cond do
      phase_idx < current_idx ->
        "bg-success/10 text-success"

      phase_idx == current_idx ->
        "bg-secondary/20 text-secondary ring-1 ring-secondary/40"

      true ->
        "bg-base-300/20 text-base-content/30"
    end
  end

  defp phase_icon(:pending), do: "hero-clock"
  defp phase_icon(:analyzing), do: "hero-magnifying-glass"
  defp phase_icon(:deliberating), do: "hero-chat-bubble-left-right"
  defp phase_icon(:voting), do: "hero-hand-raised"
  defp phase_icon(:completed), do: "hero-check-circle"
  defp phase_icon(:wiped), do: "hero-trash"
  defp phase_icon(_), do: "hero-question-mark-circle"

  defp format_phase(:pending), do: "Spawn"
  defp format_phase(:analyzing), do: "Analyze"
  defp format_phase(:deliberating), do: "Debate"
  defp format_phase(:voting), do: "Vote"
  defp format_phase(:completed), do: "Verdict"
  defp format_phase(:wiped), do: "Wiped"
  defp format_phase(phase), do: to_string(phase)

  defp vote_color(:allow), do: "text-success"
  defp vote_color(:flag), do: "text-warning"
  defp vote_color(:block), do: "text-error"
  defp vote_color(_), do: "text-base-content/60"

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
end
