defmodule SwarmshieldWeb.AuditLive do
  @moduledoc """
  Paginated, filterable audit log for all system actions.

  Displays immutable audit entries with search, filtering by action/resource_type/date,
  and highlights GhostProtocol wipe entries. Uses streams for efficient DOM updates.
  All data loaded via Accounts context functions.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Accounts
  alias SwarmshieldWeb.Hooks.AuthHooks

  @page_size 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Audit Log")
     |> assign(:page_size, @page_size)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "audit:view") do
      {:noreply, apply_filters(socket, params)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view audit logs.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  # -------------------------------------------------------------------
  # Events
  # -------------------------------------------------------------------

  @impl true
  def handle_event("filter", params, socket) do
    filter_params =
      %{}
      |> maybe_put_param("action", params["action"])
      |> maybe_put_param("resource_type", params["resource_type"])
      |> maybe_put_param("search", params["search"])

    {:noreply, push_patch(socket, to: ~p"/audit?#{filter_params}")}
  end

  def handle_event("search", %{"search" => search}, socket) do
    filter_params =
      socket.assigns.filter_params
      |> Map.put("search", search)
      |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/audit?#{filter_params}")}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/audit")}
  end

  def handle_event("load_more", _params, socket) do
    %{page: page, filter_params: filter_params} = socket.assigns
    next_params = Map.put(filter_params, "page", page + 1)
    {:noreply, push_patch(socket, to: ~p"/audit?#{next_params}")}
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp apply_filters(socket, params) do
    workspace_id = socket.assigns.current_workspace.id
    page = parse_page(params["page"])

    filter_opts = build_filter_opts(params)
    query_opts = [{:page, page}, {:page_size, @page_size} | filter_opts]

    {entries, total_count} = Accounts.list_audit_entries(workspace_id, query_opts)
    actions = Accounts.list_audit_actions(workspace_id)
    resource_types = Accounts.list_audit_resource_types(workspace_id)

    filter_params =
      params
      |> Map.take(["action", "resource_type", "search", "page"])
      |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
      |> Map.new()

    can_export? = AuthHooks.has_socket_permission?(socket, "audit:export")

    socket
    |> assign(:page, page)
    |> assign(:total_count, total_count)
    |> assign(:has_more?, total_count > page * @page_size)
    |> assign(:filter_params, filter_params)
    |> assign(:actions_for_select, actions)
    |> assign(:resource_types_for_select, resource_types)
    |> assign(:active_action, params["action"])
    |> assign(:active_resource_type, params["resource_type"])
    |> assign(:search_term, params["search"] || "")
    |> assign(:has_active_filters?, filter_params |> Map.drop(["page"]) |> map_size() > 0)
    |> assign(:can_export?, can_export?)
    |> stream(:entries, entries, reset: true)
  end

  defp build_filter_opts(params) do
    []
    |> maybe_add_filter(:action, params["action"])
    |> maybe_add_filter(:resource_type, params["resource_type"])
    |> maybe_add_filter(:search, params["search"])
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
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
      active_nav={:audit}
    >
      <div class="space-y-6">
        <%!-- Header --%>
        <div
          id="audit-header"
          class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4"
        >
          <div>
            <h1 class="text-2xl font-bold tracking-tight">
              <.icon
                name="hero-document-magnifying-glass"
                class="size-6 inline-block mr-1 text-primary"
              /> Audit Log
            </h1>
            <p class="text-sm text-base-content/50 mt-1">
              {@total_count} {if @total_count == 1, do: "entry", else: "entries"}
            </p>
          </div>
          <div :if={@can_export?} class="shrink-0">
            <button
              class="btn btn-sm btn-outline gap-1.5"
              disabled
              title="Export coming soon"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Export
            </button>
          </div>
        </div>

        <%!-- Filters --%>
        <div id="audit-filters" class="rounded-xl border border-base-300/50 bg-base-100 p-4">
          <form phx-change="filter" phx-submit="search" class="flex flex-col sm:flex-row gap-3">
            <div class="flex-1">
              <input
                type="text"
                name="search"
                value={@search_term}
                placeholder="Search by actor email or resource ID..."
                class="input input-sm input-bordered w-full"
                phx-debounce="300"
              />
            </div>
            <select name="action" class="select select-sm select-bordered">
              <option value="">All Actions</option>
              <option
                :for={action <- @actions_for_select}
                value={action}
                selected={@active_action == action}
              >
                {action}
              </option>
            </select>
            <select name="resource_type" class="select select-sm select-bordered">
              <option value="">All Resources</option>
              <option
                :for={rt <- @resource_types_for_select}
                value={rt}
                selected={@active_resource_type == rt}
              >
                {rt}
              </option>
            </select>
            <button
              :if={@has_active_filters?}
              type="button"
              phx-click="clear_filters"
              class="btn btn-sm btn-ghost gap-1"
            >
              <.icon name="hero-x-mark" class="size-3.5" /> Clear
            </button>
          </form>
        </div>

        <%!-- Entries Table --%>
        <div id="audit-entries" class="overflow-x-auto rounded-xl border border-base-300/50">
          <table class="table table-sm">
            <thead class="bg-base-200/40">
              <tr>
                <th class="text-xs font-medium uppercase tracking-wider">Timestamp</th>
                <th class="text-xs font-medium uppercase tracking-wider">Action</th>
                <th class="text-xs font-medium uppercase tracking-wider">Resource</th>
                <th class="text-xs font-medium uppercase tracking-wider">Actor</th>
                <th class="text-xs font-medium uppercase tracking-wider">IP</th>
                <th class="text-xs font-medium uppercase tracking-wider">Details</th>
              </tr>
            </thead>
            <tbody id="entries-stream" phx-update="stream" class="divide-y divide-base-300/30">
              <tr
                :for={{dom_id, entry} <- @streams.entries}
                id={dom_id}
                class={[
                  "hover:bg-base-200/30 transition-colors",
                  if(ghost_protocol_wipe?(entry), do: "bg-secondary/5", else: "")
                ]}
              >
                <td class="text-xs font-mono tabular-nums whitespace-nowrap text-base-content/60">
                  {Calendar.strftime(entry.inserted_at, "%Y-%m-%d %H:%M:%S")}
                </td>
                <td>
                  <.action_badge action={entry.action} />
                </td>
                <td>
                  <div class="text-xs">
                    <span class="font-medium">{entry.resource_type}</span>
                    <p
                      :if={entry.resource_id}
                      class="font-mono text-[10px] text-base-content/40 truncate max-w-[120px]"
                      title={entry.resource_id}
                    >
                      {String.slice(to_string(entry.resource_id), 0, 8)}...
                    </p>
                  </div>
                </td>
                <td
                  class="text-xs text-base-content/60 max-w-[160px] truncate"
                  title={entry.actor_email}
                >
                  {entry.actor_email || "system"}
                </td>
                <td class="text-xs font-mono text-base-content/40">
                  {entry.ip_address || "—"}
                </td>
                <td>
                  <.metadata_preview
                    metadata={entry.metadata}
                    ghost_wipe?={ghost_protocol_wipe?(entry)}
                  />
                </td>
              </tr>
            </tbody>
          </table>

          <%!-- Empty State --%>
          <div
            :if={@total_count == 0}
            class="py-16 text-center"
          >
            <.icon
              name="hero-document-magnifying-glass"
              class="size-12 text-base-content/15 mx-auto mb-3"
            />
            <p class="text-base-content/40 font-medium">No audit entries found</p>
            <p :if={@has_active_filters?} class="text-sm text-base-content/30 mt-1">
              Try adjusting your filters
            </p>
          </div>
        </div>

        <%!-- Load More --%>
        <div :if={@has_more?} class="flex justify-center">
          <button phx-click="load_more" class="btn btn-sm btn-ghost gap-1.5">
            <.icon name="hero-arrow-down" class="size-3.5" /> Load more
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Components
  # -------------------------------------------------------------------

  attr :action, :string, required: true

  defp action_badge(%{action: action} = assigns) do
    assigns = assign(assigns, :badge_class, action_badge_class(action))

    ~H"""
    <span class={[
      "inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium whitespace-nowrap",
      @badge_class
    ]}>
      <.icon :if={ghost_protocol_action?(@action)} name="hero-eye-slash" class="size-3" />
      {@action}
    </span>
    """
  end

  attr :metadata, :map, required: true
  attr :ghost_wipe?, :boolean, default: false

  defp metadata_preview(%{metadata: nil} = assigns) do
    ~H"""
    <span class="text-xs text-base-content/30">—</span>
    """
  end

  defp metadata_preview(%{metadata: meta} = assigns) when map_size(meta) == 0 do
    assigns = assign(assigns, :_meta, meta)

    ~H"""
    <span class="text-xs text-base-content/30">—</span>
    """
  end

  defp metadata_preview(%{ghost_wipe?: true} = assigns) do
    ~H"""
    <div class="space-y-0.5">
      <div :if={@metadata["fields_wiped"]} class="text-[10px]">
        <span class="text-secondary/60">Fields:</span>
        <span class="font-mono text-secondary">
          {Enum.join(List.wrap(@metadata["fields_wiped"]), ", ")}
        </span>
      </div>
      <div :if={@metadata["crypto_shred"]} class="text-[10px]">
        <span class="inline-flex items-center gap-0.5 px-1.5 py-0.5 rounded bg-error/10 text-error font-medium">
          <.icon name="hero-fire" class="size-2.5" /> Crypto Shred
        </span>
      </div>
      <.metadata_text
        :if={!@metadata["fields_wiped"] && !@metadata["crypto_shred"]}
        metadata={@metadata}
      />
    </div>
    """
  end

  defp metadata_preview(assigns) do
    ~H"""
    <.metadata_text metadata={@metadata} />
    """
  end

  attr :metadata, :map, required: true

  defp metadata_text(assigns) do
    preview = Jason.encode!(assigns.metadata) |> String.slice(0, 100)
    truncated? = byte_size(Jason.encode!(assigns.metadata)) > 100
    assigns = assign(assigns, preview: preview, truncated?: truncated?)

    ~H"""
    <span
      class="text-[10px] text-base-content/40 font-mono break-all"
      title={Jason.encode!(@metadata)}
    >
      {@preview}{if @truncated?, do: "…", else: ""}
    </span>
    """
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp ghost_protocol_wipe?(entry) do
    entry.action in ["ghost_protocol_wipe", "ghost_protocol_crypto_shred"]
  end

  defp ghost_protocol_action?(action) do
    String.starts_with?(to_string(action), "ghost_protocol")
  end

  defp action_badge_class(action) do
    cond do
      ghost_protocol_action?(action) -> "bg-secondary/10 text-secondary"
      String.contains?(action, "create") -> "bg-success/10 text-success"
      String.contains?(action, "update") -> "bg-info/10 text-info"
      String.contains?(action, "delete") -> "bg-error/10 text-error"
      String.contains?(action, "login") -> "bg-primary/10 text-primary"
      true -> "bg-base-300/30 text-base-content/60"
    end
  end
end
