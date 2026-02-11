defmodule SwarmshieldWeb.EventsLive do
  @moduledoc """
  Real-time event stream with composable filters, search, and pagination.

  Uses LiveView streams for efficient DOM updates. PubSub subscription
  prepends new events in real-time. All data loaded via Gateway context.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Gateway
  alias SwarmshieldWeb.Hooks.AuthHooks

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    workspace_id = socket.assigns.current_workspace.id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "events:#{workspace_id}")
    end

    {:ok,
     socket
     |> assign(:page_title, "Events")
     |> assign(:page_size, @page_size)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "events:view") do
      {:noreply, apply_filters(socket, params)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view events.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  # -------------------------------------------------------------------
  # Events: filter changes
  # -------------------------------------------------------------------

  @impl true
  def handle_event("filter", params, socket) do
    filter_params =
      %{}
      |> maybe_put_param("status", params["status"])
      |> maybe_put_param("event_type", params["event_type"])
      |> maybe_put_param("agent", params["agent"])
      |> maybe_put_param("search", params["search"])

    {:noreply, push_patch(socket, to: ~p"/events?#{filter_params}")}
  end

  def handle_event("search", %{"search" => search}, socket) do
    filter_params =
      socket.assigns.filter_params
      |> Map.put("search", search)
      |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/events?#{filter_params}")}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/events")}
  end

  def handle_event("load_more", _params, socket) do
    %{page: page, filter_params: filter_params} = socket.assigns
    next_params = Map.put(filter_params, "page", page + 1)
    {:noreply, push_patch(socket, to: ~p"/events?#{next_params}")}
  end

  # -------------------------------------------------------------------
  # PubSub: real-time new events
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:event_created, event}, socket) do
    # Only prepend if event matches current filters (or no filters active)
    if event_matches_filters?(event, socket.assigns) do
      {:noreply,
       socket
       |> stream_insert(:events, event, at: 0)
       |> update(:total_count, &(&1 + 1))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:violation_created, _violation}, socket) do
    {:noreply, socket}
  end

  def handle_info({:trigger_deliberation, _event_id, _workflow}, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private: data loading
  # -------------------------------------------------------------------

  defp apply_filters(socket, params) do
    workspace_id = socket.assigns.current_workspace.id
    page = parse_page(params["page"])

    filter_opts = build_filter_opts(params)
    query_opts = [{:page, page}, {:page_size, @page_size} | filter_opts]

    {events, total_count} = Gateway.list_agent_events(workspace_id, query_opts)
    agents_for_select = Gateway.list_agents_for_select(workspace_id)

    # Keep raw filter params for URL reconstruction
    filter_params =
      params
      |> Map.take(["status", "event_type", "agent", "search", "page"])
      |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
      |> Map.new()

    socket
    |> assign(:page, page)
    |> assign(:total_count, total_count)
    |> assign(:has_more?, total_count > page * @page_size)
    |> assign(:filter_params, filter_params)
    |> assign(:agents_for_select, agents_for_select)
    |> assign(:active_status, params["status"])
    |> assign(:active_event_type, params["event_type"])
    |> assign(:active_agent, params["agent"])
    |> assign(:search_term, params["search"] || "")
    |> assign(:has_active_filters?, filter_params |> Map.drop(["page"]) |> map_size() > 0)
    |> stream(:events, events, reset: true)
  end

  defp build_filter_opts(params) do
    []
    |> maybe_add_filter(:status, params["status"])
    |> maybe_add_filter(:event_type, params["event_type"])
    |> maybe_add_filter(:registered_agent_id, params["agent"])
    |> maybe_add_filter(:search, params["search"])
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts

  defp maybe_add_filter(opts, key, value) when key in [:status, :event_type] do
    [{key, String.to_existing_atom(value)} | opts]
  rescue
    ArgumentError -> opts
  end

  defp maybe_add_filter(opts, key, value), do: [{key, value} | opts]

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

  defp event_matches_filters?(event, assigns) do
    matches_status?(event, assigns.active_status) and
      matches_event_type?(event, assigns.active_event_type) and
      matches_agent?(event, assigns.active_agent) and
      matches_search?(event, assigns.search_term)
  end

  defp matches_status?(_event, nil), do: true
  defp matches_status?(_event, ""), do: true
  defp matches_status?(event, status), do: to_string(event.status) == status

  defp matches_event_type?(_event, nil), do: true
  defp matches_event_type?(_event, ""), do: true
  defp matches_event_type?(event, type), do: to_string(event.event_type) == type

  defp matches_agent?(_event, nil), do: true
  defp matches_agent?(_event, ""), do: true
  defp matches_agent?(event, agent_id), do: event.registered_agent_id == agent_id

  defp matches_search?(_event, ""), do: true
  defp matches_search?(_event, nil), do: true

  defp matches_search?(event, search) do
    String.contains?(String.downcase(event.content || ""), String.downcase(search))
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
      active_nav={:events}
    >
      <div class="space-y-6">
        <%!-- Page Header --%>
        <div
          id="events-header"
          class="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4"
        >
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Event Stream</h1>
            <p class="text-sm text-base-content/50 mt-1">
              <span class="tabular-nums font-medium">{format_count(@total_count)}</span>
              events in {@current_workspace.name}
            </p>
          </div>
          <div class="flex items-center gap-2">
            <div class="size-2 rounded-full bg-success animate-pulse" />
            <span class="text-xs text-base-content/40">Live</span>
          </div>
        </div>

        <%!-- Filter Bar --%>
        <div id="filter-bar" class="rounded-xl border border-base-300/50 bg-base-100 p-4">
          <form phx-change="filter" phx-submit="filter" class="space-y-3">
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
              <%!-- Status filter --%>
              <div>
                <label class="text-xs font-medium text-base-content/50 mb-1 block">Status</label>
                <select
                  name="status"
                  class="select select-bordered select-sm w-full"
                  value={@active_status}
                >
                  <option value="">All statuses</option>
                  <option value="pending" selected={@active_status == "pending"}>Pending</option>
                  <option value="allowed" selected={@active_status == "allowed"}>Allowed</option>
                  <option value="flagged" selected={@active_status == "flagged"}>Flagged</option>
                  <option value="blocked" selected={@active_status == "blocked"}>Blocked</option>
                </select>
              </div>

              <%!-- Event Type filter --%>
              <div>
                <label class="text-xs font-medium text-base-content/50 mb-1 block">Type</label>
                <select
                  name="event_type"
                  class="select select-bordered select-sm w-full"
                  value={@active_event_type}
                >
                  <option value="">All types</option>
                  <option value="action" selected={@active_event_type == "action"}>Action</option>
                  <option value="output" selected={@active_event_type == "output"}>Output</option>
                  <option value="tool_call" selected={@active_event_type == "tool_call"}>
                    Tool Call
                  </option>
                  <option value="message" selected={@active_event_type == "message"}>Message</option>
                  <option value="error" selected={@active_event_type == "error"}>Error</option>
                </select>
              </div>

              <%!-- Agent filter --%>
              <div>
                <label class="text-xs font-medium text-base-content/50 mb-1 block">Agent</label>
                <select
                  name="agent"
                  class="select select-bordered select-sm w-full"
                  value={@active_agent}
                >
                  <option value="">All agents</option>
                  <option
                    :for={{name, id} <- @agents_for_select}
                    value={id}
                    selected={@active_agent == id}
                  >
                    {name}
                  </option>
                </select>
              </div>

              <%!-- Search --%>
              <div>
                <label class="text-xs font-medium text-base-content/50 mb-1 block">Search</label>
                <div class="relative">
                  <input
                    type="text"
                    name="search"
                    value={@search_term}
                    placeholder="Search content..."
                    phx-debounce="300"
                    class="input input-bordered input-sm w-full pr-8"
                  />
                  <.icon
                    name="hero-magnifying-glass"
                    class="size-4 text-base-content/30 absolute right-2 top-1/2 -translate-y-1/2"
                  />
                </div>
              </div>
            </div>

            <%!-- Active filter indicator + clear --%>
            <div :if={@has_active_filters?} class="flex items-center gap-2 pt-1">
              <span class="text-xs text-base-content/40">Filters active</span>
              <button
                type="button"
                phx-click="clear_filters"
                class="btn btn-ghost btn-xs gap-1"
              >
                <.icon name="hero-x-mark" class="size-3" /> Clear all
              </button>
            </div>
          </form>
        </div>

        <%!-- Events Table --%>
        <div class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm" id="events-table">
              <thead>
                <tr class="border-b border-base-300/50">
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Type
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Content
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Agent
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
              <tbody id="events-stream" phx-update="stream">
                <tr
                  :for={{dom_id, event} <- @streams.events}
                  id={dom_id}
                  class="border-b border-base-300/30 hover:bg-base-200/50 transition-colors cursor-pointer"
                  phx-click={JS.navigate(~p"/events/#{event.id}")}
                >
                  <td>
                    <.status_badge status={event.status} />
                  </td>
                  <td>
                    <.type_badge type={event.event_type} />
                  </td>
                  <td class="max-w-xs">
                    <p class="truncate text-sm">{event.content}</p>
                  </td>
                  <td>
                    <span class="text-sm text-base-content/70">
                      {agent_name(event)}
                    </span>
                  </td>
                  <td>
                    <.severity_indicator severity={event.severity} />
                  </td>
                  <td>
                    <span class="text-xs text-base-content/50 tabular-nums">
                      {format_time(event.inserted_at)}
                    </span>
                  </td>
                  <td>
                    <.icon
                      name="hero-chevron-right-mini"
                      class="size-4 text-base-content/20"
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Empty state --%>
          <div
            :if={@total_count == 0}
            id="events-empty"
            class="p-12 text-center"
          >
            <.icon name="hero-inbox" class="size-12 text-base-content/20 mx-auto mb-4" />
            <p class="text-base-content/50 font-medium">No events yet</p>
            <p class="text-sm text-base-content/30 mt-1">
              Events will appear here when agents send data through the API gateway.
            </p>
          </div>

          <%!-- Pagination --%>
          <div
            :if={@has_more?}
            class="p-4 border-t border-base-300/30 text-center"
          >
            <button
              phx-click="load_more"
              class="btn btn-ghost btn-sm gap-2"
            >
              <.icon name="hero-arrow-down" class="size-4" /> Load more events
              <span class="badge badge-ghost badge-sm tabular-nums">
                {format_count(@total_count - @page * @page_size)} remaining
              </span>
            </button>
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

  attr :severity, :atom, required: true

  defp severity_indicator(assigns) do
    ~H"""
    <span class={["text-xs font-medium", severity_color(@severity)]}>
      {format_severity(@severity)}
    </span>
    """
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp agent_name(%{registered_agent: %{name: name}}) when is_binary(name), do: name
  defp agent_name(_event), do: "Unknown"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %H:%M:%S")
  end

  defp format_time(_), do: ""

  defp format_count(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_count(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}K"
  end

  defp format_count(n) when is_integer(n) and n < 0, do: "0"
  defp format_count(n) when is_integer(n), do: Integer.to_string(n)
  defp format_count(_), do: "0"

  defp format_type(:tool_call), do: "Tool Call"
  defp format_type(type), do: type |> to_string() |> String.capitalize()

  defp type_classes(:action), do: "bg-info/10 text-info"
  defp type_classes(:output), do: "bg-primary/10 text-primary"
  defp type_classes(:tool_call), do: "bg-accent/10 text-accent"
  defp type_classes(:message), do: "bg-base-300/30 text-base-content/60"
  defp type_classes(:error), do: "bg-error/10 text-error"
  defp type_classes(_), do: "bg-base-300/30 text-base-content/60"

  defp severity_color(:critical), do: "text-error"
  defp severity_color(:error), do: "text-error/70"
  defp severity_color(:warning), do: "text-warning"
  defp severity_color(:info), do: "text-base-content/40"
  defp severity_color(_), do: "text-base-content/40"

  defp format_severity(:critical), do: "CRITICAL"
  defp format_severity(:error), do: "ERROR"
  defp format_severity(:warning), do: "WARN"
  defp format_severity(:info), do: "INFO"
  defp format_severity(_), do: "-"
end
