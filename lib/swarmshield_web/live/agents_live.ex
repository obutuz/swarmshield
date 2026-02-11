defmodule SwarmshieldWeb.AgentsLive do
  @moduledoc """
  Registered agent registry with filters and real-time status.

  Displays all monitored AI agents with status, risk level, event counts.
  Uses streams for efficient DOM updates.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Gateway
  alias SwarmshieldWeb.Hooks.AuthHooks

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Agent Registry")
     |> assign(:page_size, @page_size)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "agents:view") do
      {:noreply, apply_filters(socket, params)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view agents.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    filter_params =
      %{}
      |> maybe_put_param("status", params["status"])
      |> maybe_put_param("agent_type", params["agent_type"])
      |> maybe_put_param("search", params["search"])

    {:noreply, push_patch(socket, to: ~p"/agents?#{filter_params}")}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/agents")}
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp apply_filters(socket, params) do
    workspace_id = socket.assigns.current_workspace.id
    page = parse_page(params["page"])

    filter_opts = build_filter_opts(params)
    query_opts = [{:page, page}, {:page_size, @page_size} | filter_opts]

    {agents, total_count} = Gateway.list_registered_agents(workspace_id, query_opts)

    filter_params =
      params
      |> Map.take(["status", "agent_type", "search", "page"])
      |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
      |> Map.new()

    socket
    |> assign(:page, page)
    |> assign(:total_count, total_count)
    |> assign(:has_more?, total_count > page * @page_size)
    |> assign(:filter_params, filter_params)
    |> assign(:active_status, params["status"])
    |> assign(:active_agent_type, params["agent_type"])
    |> assign(:search_term, params["search"] || "")
    |> assign(:has_active_filters?, filter_params |> Map.drop(["page"]) |> map_size() > 0)
    |> stream(:agents, agents, reset: true)
  end

  defp build_filter_opts(params) do
    []
    |> maybe_add_filter(:status, params["status"])
    |> maybe_add_filter(:agent_type, params["agent_type"])
    |> maybe_add_search(:search, params["search"])
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts

  defp maybe_add_filter(opts, key, value) do
    [{key, String.to_existing_atom(value)} | opts]
  rescue
    ArgumentError -> opts
  end

  defp maybe_add_search(opts, _key, nil), do: opts
  defp maybe_add_search(opts, _key, ""), do: opts
  defp maybe_add_search(opts, key, value), do: [{key, value} | opts]

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
      active_nav={:agents}
    >
      <div class="space-y-6">
        <%!-- Header --%>
        <div
          id="agents-header"
          class="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4"
        >
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Agent Registry</h1>
            <p class="text-sm text-base-content/50 mt-1">
              <span class="tabular-nums font-medium">{@total_count}</span> registered agents
            </p>
          </div>
        </div>

        <%!-- Filter Bar --%>
        <div id="filter-bar" class="rounded-xl border border-base-300/50 bg-base-100 p-4">
          <form phx-change="filter" phx-submit="filter" class="space-y-3">
            <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
              <div>
                <label class="text-xs font-medium text-base-content/50 mb-1 block">Status</label>
                <select
                  name="status"
                  class="select select-bordered select-sm w-full"
                  value={@active_status}
                >
                  <option value="">All statuses</option>
                  <option value="active" selected={@active_status == "active"}>Active</option>
                  <option value="suspended" selected={@active_status == "suspended"}>
                    Suspended
                  </option>
                  <option value="revoked" selected={@active_status == "revoked"}>Revoked</option>
                </select>
              </div>
              <div>
                <label class="text-xs font-medium text-base-content/50 mb-1 block">Type</label>
                <select
                  name="agent_type"
                  class="select select-bordered select-sm w-full"
                  value={@active_agent_type}
                >
                  <option value="">All types</option>
                  <option value="autonomous" selected={@active_agent_type == "autonomous"}>
                    Autonomous
                  </option>
                  <option value="semi_autonomous" selected={@active_agent_type == "semi_autonomous"}>
                    Semi-Autonomous
                  </option>
                  <option value="tool_agent" selected={@active_agent_type == "tool_agent"}>
                    Tool Agent
                  </option>
                  <option value="chatbot" selected={@active_agent_type == "chatbot"}>
                    Chatbot
                  </option>
                </select>
              </div>
              <div>
                <label class="text-xs font-medium text-base-content/50 mb-1 block">Search</label>
                <div class="relative">
                  <input
                    type="text"
                    name="search"
                    value={@search_term}
                    placeholder="Search by name..."
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
            <div :if={@has_active_filters?} class="flex items-center gap-2 pt-1">
              <span class="text-xs text-base-content/40">Filters active</span>
              <button type="button" phx-click="clear_filters" class="btn btn-ghost btn-xs gap-1">
                <.icon name="hero-x-mark" class="size-3" /> Clear all
              </button>
            </div>
          </form>
        </div>

        <%!-- Agents Table --%>
        <div class="rounded-xl border border-base-300/50 bg-base-100 overflow-hidden">
          <div class="overflow-x-auto">
            <table class="table table-sm" id="agents-table">
              <thead>
                <tr class="border-b border-base-300/50">
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Agent
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Type
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Risk
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Events
                  </th>
                  <th class="text-xs font-medium text-base-content/50 uppercase tracking-wider">
                    Last Seen
                  </th>
                  <th class="w-10"></th>
                </tr>
              </thead>
              <tbody id="agents-stream" phx-update="stream">
                <tr
                  :for={{dom_id, agent} <- @streams.agents}
                  id={dom_id}
                  class="border-b border-base-300/30 hover:bg-base-200/50 transition-colors cursor-pointer"
                  phx-click={JS.navigate(~p"/agents/#{agent.id}")}
                >
                  <td>
                    <div class="flex items-center gap-3">
                      <div class="flex items-center justify-center size-8 rounded-lg bg-primary/10">
                        <.icon name="hero-cpu-chip" class="size-4 text-primary" />
                      </div>
                      <div>
                        <p class="text-sm font-medium">{agent.name}</p>
                        <p class="text-xs text-base-content/40 font-mono">
                          {agent.api_key_prefix}...
                        </p>
                      </div>
                    </div>
                  </td>
                  <td>
                    <.agent_type_badge type={agent.agent_type} />
                  </td>
                  <td>
                    <.agent_status_badge status={agent.status} />
                  </td>
                  <td>
                    <.risk_badge level={agent.risk_level} />
                  </td>
                  <td>
                    <span class="text-sm tabular-nums">{agent.event_count}</span>
                  </td>
                  <td>
                    <span class="text-xs text-base-content/50">
                      {format_relative_time(agent.last_seen_at)}
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
          <div :if={@total_count == 0} id="agents-empty" class="p-12 text-center">
            <.icon name="hero-cpu-chip" class="size-12 text-base-content/20 mx-auto mb-4" />
            <p class="text-base-content/50 font-medium">No agents registered</p>
            <p class="text-sm text-base-content/30 mt-1">
              Agents will appear here when they authenticate via the API gateway.
            </p>
          </div>

          <%!-- Pagination --%>
          <div :if={@has_more?} class="p-4 border-t border-base-300/30 text-center">
            <.link
              patch={~p"/agents?#{Map.put(@filter_params, "page", @page + 1)}"}
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

  attr :type, :atom, required: true

  defp agent_type_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium",
      type_classes(@type)
    ]}>
      {format_agent_type(@type)}
    </span>
    """
  end

  attr :status, :atom, required: true

  defp agent_status_badge(%{status: :active} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-success/10 text-success">
      <span class="size-1.5 rounded-full bg-success" /> Active
    </span>
    """
  end

  defp agent_status_badge(%{status: :suspended} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-warning/10 text-warning">
      <span class="size-1.5 rounded-full bg-warning" /> Suspended
    </span>
    """
  end

  defp agent_status_badge(%{status: :revoked} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-error/10 text-error">
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
    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-bold bg-error/10 text-error">
      CRITICAL
    </span>
    """
  end

  defp risk_badge(%{level: :high} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-error/10 text-error/80">
      HIGH
    </span>
    """
  end

  defp risk_badge(%{level: :medium} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-warning/10 text-warning">
      MEDIUM
    </span>
    """
  end

  defp risk_badge(%{level: :low} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-success/10 text-success">
      LOW
    </span>
    """
  end

  defp risk_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-sm">{@level}</span>
    """
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp format_agent_type(:autonomous), do: "Autonomous"
  defp format_agent_type(:semi_autonomous), do: "Semi-Auto"
  defp format_agent_type(:tool_agent), do: "Tool Agent"
  defp format_agent_type(:chatbot), do: "Chatbot"
  defp format_agent_type(type), do: type |> to_string() |> String.capitalize()

  defp type_classes(:autonomous), do: "bg-info/10 text-info"
  defp type_classes(:semi_autonomous), do: "bg-primary/10 text-primary"
  defp type_classes(:tool_agent), do: "bg-accent/10 text-accent"
  defp type_classes(:chatbot), do: "bg-base-300/30 text-base-content/60"
  defp type_classes(_), do: "bg-base-300/30 text-base-content/60"

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
end
