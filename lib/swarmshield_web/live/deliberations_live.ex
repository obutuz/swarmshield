defmodule SwarmshieldWeb.DeliberationsLive do
  @moduledoc """
  Deliberation sessions list with GhostProtocol status visibility.

  Shows all analysis sessions with status, workflow, verdict, and
  ephemeral indicator. Subscribes to PubSub for real-time updates.
  Uses streams for efficient DOM updates.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Deliberation
  alias SwarmshieldWeb.Hooks.AuthHooks

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Deliberations")
     |> assign(:page_size, @page_size)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "deliberations:view") do
      workspace_id = socket.assigns.current_workspace.id

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Swarmshield.PubSub, "deliberations:#{workspace_id}")
        Phoenix.PubSub.subscribe(Swarmshield.PubSub, "ghost_protocol:#{workspace_id}")
      end

      {:noreply, apply_filters(socket, params)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view deliberations.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    filter_params =
      %{}
      |> maybe_put_param("status", params["status"])
      |> maybe_put_param("trigger", params["trigger"])

    {:noreply, push_patch(socket, to: ~p"/deliberations?#{filter_params}")}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/deliberations")}
  end

  @impl true
  def handle_info({:session_created, session}, socket) do
    {:noreply,
     socket
     |> stream_insert(:sessions, session, at: 0)
     |> assign(:total_count, socket.assigns.total_count + 1)}
  end

  def handle_info({:session_updated, session}, socket) do
    {:noreply, stream_insert(socket, :sessions, session)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp apply_filters(socket, params) do
    workspace_id = socket.assigns.current_workspace.id
    page = parse_page(params["page"])

    filter_opts = build_filter_opts(params)
    query_opts = [{:page, page}, {:page_size, @page_size} | filter_opts]

    {sessions, total_count} = Deliberation.list_analysis_sessions(workspace_id, query_opts)

    filter_params =
      params
      |> Map.take(["status", "trigger", "page"])
      |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
      |> Map.new()

    socket
    |> assign(:page, page)
    |> assign(:total_count, total_count)
    |> assign(:has_more?, total_count > page * @page_size)
    |> assign(:filter_params, filter_params)
    |> assign(:active_status, params["status"])
    |> assign(:active_trigger, params["trigger"])
    |> assign(:has_active_filters?, filter_params |> Map.drop(["page"]) |> map_size() > 0)
    |> stream(:sessions, sessions, reset: true)
  end

  defp build_filter_opts(params) do
    []
    |> maybe_add_filter(:status, params["status"])
    |> maybe_add_filter(:trigger, params["trigger"])
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts

  defp maybe_add_filter(opts, key, value) do
    [{key, String.to_existing_atom(value)} | opts]
  rescue
    ArgumentError -> opts
  end

  defp parse_page(nil), do: 1

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp maybe_put_param(map, _key, nil), do: map
  defp maybe_put_param(map, _key, ""), do: map
  defp maybe_put_param(map, key, value), do: Map.put(map, key, value)

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
        <%!-- Header --%>
        <div
          id="deliberations-header"
          class="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4"
        >
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Deliberation Sessions</h1>
            <p class="text-sm text-base-content/50 mt-1">
              <span class="tabular-nums font-medium">{@total_count}</span> sessions
            </p>
          </div>
        </div>

        <%!-- Filter Bar --%>
        <div id="filter-bar" class="rounded-xl border border-base-300/50 bg-base-100 p-4">
          <form phx-change="filter" phx-submit="filter" class="space-y-3">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div>
                <label class="text-xs font-medium text-base-content/50 mb-1 block">Status</label>
                <select
                  name="status"
                  class="select select-bordered select-sm w-full"
                  value={@active_status}
                >
                  <option value="">All statuses</option>
                  <option value="pending" selected={@active_status == "pending"}>Pending</option>
                  <option value="analyzing" selected={@active_status == "analyzing"}>
                    Analyzing
                  </option>
                  <option value="deliberating" selected={@active_status == "deliberating"}>
                    Deliberating
                  </option>
                  <option value="voting" selected={@active_status == "voting"}>Voting</option>
                  <option value="completed" selected={@active_status == "completed"}>
                    Completed
                  </option>
                  <option value="failed" selected={@active_status == "failed"}>Failed</option>
                  <option value="timed_out" selected={@active_status == "timed_out"}>
                    Timed Out
                  </option>
                </select>
              </div>
              <div>
                <label class="text-xs font-medium text-base-content/50 mb-1 block">Trigger</label>
                <select
                  name="trigger"
                  class="select select-bordered select-sm w-full"
                  value={@active_trigger}
                >
                  <option value="">All triggers</option>
                  <option value="automatic" selected={@active_trigger == "automatic"}>
                    Automatic
                  </option>
                  <option value="manual" selected={@active_trigger == "manual"}>Manual</option>
                </select>
              </div>
            </div>
            <div :if={@has_active_filters?} class="flex items-center gap-2 pt-1">
              <span class="text-xs text-base-content/40">Filters active</span>
              <button type="button" phx-click="clear_filters" class="btn btn-ghost btn-xs gap-1">
                <.icon name="hero-x-mark" class="size-3" /> Clear all
              </button>
            </div>
          </form>
        </div>

        <%!-- Sessions Table --%>
        <div class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm" id="sessions-table">
              <thead>
                <tr class="border-b border-base-300/50">
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Workflow
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Trigger
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Verdict
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Confidence
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Cost
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Ghost
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Time
                  </th>
                  <th class="w-10"></th>
                </tr>
              </thead>
              <tbody id="sessions-stream" phx-update="stream">
                <tr
                  :for={{dom_id, session} <- @streams.sessions}
                  id={dom_id}
                  class="border-b border-base-300/30 hover:bg-base-200/50 transition-colors cursor-pointer"
                  phx-click={JS.navigate(~p"/deliberations/#{session.id}")}
                >
                  <td>
                    <.session_status_badge status={session.status} />
                  </td>
                  <td>
                    <span class="text-sm font-medium">
                      {workflow_name(session)}
                    </span>
                  </td>
                  <td>
                    <.trigger_badge trigger={session.trigger} />
                  </td>
                  <td>
                    <.verdict_badge verdict={session.verdict} />
                  </td>
                  <td>
                    <span :if={session.verdict} class="text-sm tabular-nums font-medium">
                      {format_confidence(session.verdict.confidence)}
                    </span>
                    <span :if={!session.verdict} class="text-xs text-base-content/30">—</span>
                  </td>
                  <td>
                    <span class="text-xs tabular-nums text-base-content/50">
                      {format_cost(session.total_cost_cents)}
                    </span>
                  </td>
                  <td>
                    <.ghost_badge session={session} />
                  </td>
                  <td>
                    <span class="text-xs text-base-content/50">
                      {format_relative_time(session.inserted_at)}
                    </span>
                  </td>
                  <td>
                    <.icon name="hero-chevron-right-mini" class="size-4 text-base-content/20" />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Empty state --%>
          <div :if={@total_count == 0} id="sessions-empty" class="p-12 text-center">
            <.icon
              name="hero-chat-bubble-left-right"
              class="size-12 text-base-content/20 mx-auto mb-4"
            />
            <p class="text-base-content/50 font-medium">No deliberation sessions</p>
            <p class="text-sm text-base-content/30 mt-1">
              Sessions will appear here when flagged events trigger the deliberation engine.
            </p>
          </div>

          <%!-- Pagination --%>
          <div :if={@has_more?} class="p-4 border-t border-base-300/30 text-center">
            <.link
              patch={~p"/deliberations?#{Map.put(@filter_params, "page", @page + 1)}"}
              class="btn btn-ghost btn-sm gap-2"
            >
              <.icon name="hero-arrow-down" class="size-4" /> Load more
            </.link>
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
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-base-300/30 text-base-content/60">
      <.icon name="hero-clock" class="size-3" /> Pending
    </span>
    """
  end

  defp session_status_badge(%{status: :analyzing} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-info/10 text-info">
      <.icon name="hero-magnifying-glass" class="size-3 animate-pulse" /> Analyzing
    </span>
    """
  end

  defp session_status_badge(%{status: :deliberating} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-primary/10 text-primary">
      <.icon name="hero-chat-bubble-left-right" class="size-3" /> Deliberating
    </span>
    """
  end

  defp session_status_badge(%{status: :voting} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-accent/10 text-accent">
      <.icon name="hero-hand-raised" class="size-3" /> Voting
    </span>
    """
  end

  defp session_status_badge(%{status: :completed} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-success/10 text-success">
      <.icon name="hero-check-circle" class="size-3" /> Completed
    </span>
    """
  end

  defp session_status_badge(%{status: :failed} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-error/10 text-error">
      <.icon name="hero-x-circle" class="size-3" /> Failed
    </span>
    """
  end

  defp session_status_badge(%{status: :timed_out} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-warning/10 text-warning">
      <.icon name="hero-clock" class="size-3" /> Timed Out
    </span>
    """
  end

  defp session_status_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-sm">{@status}</span>
    """
  end

  attr :trigger, :atom, required: true

  defp trigger_badge(%{trigger: :automatic} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium bg-info/10 text-info">
      <.icon name="hero-bolt" class="size-3" /> Auto
    </span>
    """
  end

  defp trigger_badge(%{trigger: :manual} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium bg-base-300/30 text-base-content/60">
      <.icon name="hero-hand-raised" class="size-3" /> Manual
    </span>
    """
  end

  defp trigger_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-sm">{@trigger}</span>
    """
  end

  attr :verdict, :any, required: true

  defp verdict_badge(%{verdict: nil} = assigns) do
    ~H"""
    <span class="text-xs text-base-content/30">—</span>
    """
  end

  defp verdict_badge(%{verdict: %{decision: :block}} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-bold bg-error/10 text-error">
      Block
    </span>
    """
  end

  defp verdict_badge(%{verdict: %{decision: :flag}} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-warning/10 text-warning">
      Flag
    </span>
    """
  end

  defp verdict_badge(%{verdict: %{decision: :allow}} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-success/10 text-success">
      Allow
    </span>
    """
  end

  defp verdict_badge(%{verdict: %{decision: :escalate}} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-bold bg-primary/10 text-primary">
      Escalate
    </span>
    """
  end

  defp verdict_badge(%{verdict: verdict} = assigns) when not is_nil(verdict) do
    ~H"""
    <span class="badge badge-ghost badge-sm">{@verdict.decision}</span>
    """
  end

  attr :session, :map, required: true

  defp ghost_badge(assigns) do
    assigns = assign(assigns, :ephemeral?, ephemeral?(assigns.session))
    ghost_badge_impl(assigns)
  end

  defp ghost_badge_impl(%{ephemeral?: false} = assigns) do
    ~H"""
    <span class="text-xs text-base-content/20">—</span>
    """
  end

  defp ghost_badge_impl(%{ephemeral?: true} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-secondary/10 text-secondary">
      <.icon name="hero-eye-slash" class="size-3" /> Ephemeral
    </span>
    """
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp workflow_name(%{workflow: %{name: name}}) when is_binary(name), do: name
  defp workflow_name(_session), do: "—"

  defp ephemeral?(%{workflow: %{ghost_protocol_config: config}})
       when not is_nil(config),
       do: true

  defp ephemeral?(_session), do: false

  defp format_confidence(nil), do: "—"
  defp format_confidence(confidence), do: "#{Float.round(confidence * 100, 1)}%"

  defp format_cost(0), do: "—"
  defp format_cost(nil), do: "—"
  defp format_cost(cents), do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

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
