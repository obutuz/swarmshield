defmodule SwarmshieldWeb.Admin.GhostProtocolConfigsLive do
  @moduledoc """
  Admin CRUD for GhostProtocol retention configurations.

  SwarmShield's flagship security feature — agents do expert work then vanish.
  Full CRUD for wipe strategy, crypto_shred, field targeting, session duration.
  Conditional fields based on wipe strategy. Delete blocked if workflows linked.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.GhostProtocol
  alias Swarmshield.GhostProtocol.Config
  alias SwarmshieldWeb.Hooks.AuthHooks

  @wipe_strategy_options [
    {"Immediate", "immediate"},
    {"Delayed", "delayed"},
    {"Scheduled", "scheduled"}
  ]

  @wipe_field_options Config.allowed_wipe_fields()
                      |> Enum.map(fn f ->
                        label =
                          f
                          |> String.replace("_", " ")
                          |> String.split(" ")
                          |> Enum.map_join(" ", &String.capitalize/1)

                        {label, f}
                      end)

  # -------------------------------------------------------------------
  # Mount
  # -------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      workspace_id = socket.assigns.current_workspace.id
      GhostProtocol.subscribe_to_workspace(workspace_id)
    end

    {:ok, assign(socket, :page_title, "GhostProtocol Configs")}
  end

  # -------------------------------------------------------------------
  # Handle params
  # -------------------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "ghost_protocol:view") do
      {:noreply, apply_action(socket, socket.assigns.live_action, params)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to manage GhostProtocol configs.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  defp apply_action(socket, :index, _params) do
    workspace_id = socket.assigns.current_workspace.id
    {configs, total_count} = GhostProtocol.list_configs(workspace_id)

    socket
    |> assign(:page_title, "GhostProtocol Configs")
    |> assign(:total_count, total_count)
    |> assign(:config, nil)
    |> assign(:form, nil)
    |> assign(:selected_strategy, "immediate")
    |> assign(:selected_wipe_fields, [])
    |> stream(:configs, configs, reset: true)
  end

  defp apply_action(socket, :new, _params) do
    config = %Config{wipe_strategy: :immediate, crypto_shred: false, enabled: true}
    changeset = GhostProtocol.change_config(config)

    socket
    |> assign(:page_title, "New GhostProtocol Config")
    |> assign(:config, config)
    |> assign(:form, to_form(changeset))
    |> assign(:selected_strategy, "immediate")
    |> assign(:selected_wipe_fields, [])
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    workspace_id = socket.assigns.current_workspace.id
    config = GhostProtocol.get_config_for_workspace!(id, workspace_id)
    changeset = GhostProtocol.change_config(config)

    socket
    |> assign(:page_title, "Edit GhostProtocol Config")
    |> assign(:config, config)
    |> assign(:form, to_form(changeset))
    |> assign(:selected_strategy, to_string(config.wipe_strategy))
    |> assign(:selected_wipe_fields, config.wipe_fields || [])
  end

  # -------------------------------------------------------------------
  # Events: Form validate + submit
  # -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"config" => params}, socket) do
    new_strategy = params["wipe_strategy"] || socket.assigns.selected_strategy

    changeset =
      (socket.assigns.config || %Config{})
      |> GhostProtocol.change_config(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:selected_strategy, new_strategy)}
  end

  def handle_event("save", %{"config" => params}, socket) do
    params = enrich_wipe_fields(params, socket)

    case socket.assigns.live_action do
      :new -> create_config(socket, params)
      :edit -> update_config(socket, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "ghost_protocol:delete") do
      delete_verified_config(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "ghost_protocol:update") do
      toggle_verified_config(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("toggle_wipe_field", %{"field" => field}, socket) do
    current = socket.assigns.selected_wipe_fields

    updated =
      if field in current do
        List.delete(current, field)
      else
        [field | current]
      end

    {:noreply, assign(socket, :selected_wipe_fields, updated)}
  end

  # -------------------------------------------------------------------
  # PubSub handlers
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:config_created, config_id}, socket) do
    workspace_id = socket.assigns.current_workspace.id

    try do
      config = GhostProtocol.get_config!(config_id)

      if config.workspace_id == workspace_id do
        {:noreply,
         socket
         |> stream_insert(:configs, config, at: 0)
         |> update(:total_count, &(&1 + 1))}
      else
        {:noreply, socket}
      end
    rescue
      Ecto.NoResultsError -> {:noreply, socket}
    end
  end

  def handle_info({:config_updated, config_id}, socket) do
    workspace_id = socket.assigns.current_workspace.id

    try do
      config = GhostProtocol.get_config!(config_id)

      if config.workspace_id == workspace_id do
        {:noreply, stream_insert(socket, :configs, config)}
      else
        {:noreply, socket}
      end
    rescue
      Ecto.NoResultsError -> {:noreply, socket}
    end
  end

  def handle_info({:config_deleted, _config_id}, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private: mutations
  # -------------------------------------------------------------------

  defp create_config(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "ghost_protocol:create") do
      workspace_id = socket.assigns.current_workspace.id

      case GhostProtocol.create_config(workspace_id, params) do
        {:ok, _config} ->
          {:noreply,
           socket
           |> put_flash(:info, "GhostProtocol config created.")
           |> push_patch(to: ~p"/admin/ghost-protocol-configs")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp update_config(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "ghost_protocol:update") do
      config = socket.assigns.config

      case GhostProtocol.update_config(config, params) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "GhostProtocol config updated.")
           |> push_patch(to: ~p"/admin/ghost-protocol-configs")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp delete_verified_config(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    config = GhostProtocol.get_config_for_workspace!(id, workspace_id)

    case GhostProtocol.delete_config(config) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> stream_delete(:configs, config)
         |> update(:total_count, &max(&1 - 1, 0))
         |> put_flash(:info, "GhostProtocol config deleted.")}

      {:error, :has_linked_workflows} ->
        workflow_count = length(config.workflows || [])

        {:noreply,
         put_flash(
           socket,
           :error,
           "Cannot delete — #{workflow_count} workflow(s) use this config."
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete config.")}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Config not found.")}
  end

  defp toggle_verified_config(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    config = GhostProtocol.get_config_for_workspace!(id, workspace_id)

    case GhostProtocol.update_config(config, %{enabled: !config.enabled}) do
      {:ok, updated} ->
        {:noreply, stream_insert(socket, :configs, updated)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update config.")}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Config not found.")}
  end

  # -------------------------------------------------------------------
  # Private: param enrichment
  # -------------------------------------------------------------------

  defp enrich_wipe_fields(params, socket) do
    Map.put(params, "wipe_fields", socket.assigns.selected_wipe_fields)
  end

  # -------------------------------------------------------------------
  # Render: Create / Edit form
  # -------------------------------------------------------------------

  @impl true
  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    assigns =
      assigns
      |> assign(:wipe_strategy_options, @wipe_strategy_options)
      |> assign(:wipe_field_options, @wipe_field_options)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_ghost_protocol}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-base-content">
              {if @live_action == :new,
                do: "New GhostProtocol Config",
                else: "Edit GhostProtocol Config"}
            </h1>
            <p class="text-base-content/70 mt-1">
              Configure ephemeral agent lifecycle and data wipe policies
            </p>
          </div>
          <.link
            patch={~p"/admin/ghost-protocol-configs"}
            class="inline-flex items-center gap-2 h-[44px] px-4 rounded-lg border-[0.5px] border-base-300 text-sm text-base-content hover:bg-base-200 transition-colors"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to Configs
          </.link>
        </div>

        <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-6">
          <.form
            for={@form}
            id="ghost-protocol-config-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-5"
          >
            <div class="grid grid-cols-1 md:grid-cols-2 gap-5">
              <div>
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Name"
                  phx-debounce="300"
                  required
                  placeholder="e.g. Standard Ephemeral"
                />
              </div>
              <div>
                <.input
                  field={@form[:slug]}
                  type="text"
                  label="Slug (auto-generated)"
                  phx-debounce="300"
                  placeholder="auto-generated-from-name"
                />
              </div>
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-5">
              <div>
                <.input
                  field={@form[:wipe_strategy]}
                  type="select"
                  label="Wipe Strategy"
                  options={@wipe_strategy_options}
                  phx-debounce="300"
                  required
                />
              </div>
              <div :if={@selected_strategy in ["delayed", "scheduled"]}>
                <.input
                  field={@form[:wipe_delay_seconds]}
                  type="number"
                  label="Wipe Delay (seconds)"
                  min="1"
                  max="86400"
                  phx-debounce="300"
                  required
                />
              </div>
            </div>

            <div>
              <.input
                field={@form[:max_session_duration_seconds]}
                type="number"
                label="Max Session Duration (seconds)"
                min="10"
                max="3600"
                phx-debounce="300"
                required
              />
              <p class="text-xs text-base-content/50 mt-1">10s to 3600s (1 hour)</p>
            </div>

            <%!-- Wipe Fields --%>
            <div class="space-y-2">
              <label class="block text-sm font-medium text-base-content/80">
                Fields to Wipe
              </label>
              <div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-2">
                <button
                  :for={{label, field} <- @wipe_field_options}
                  type="button"
                  phx-click="toggle_wipe_field"
                  phx-value-field={field}
                  class={[
                    "flex items-center gap-2 px-3 py-2 rounded-lg border-[0.5px] text-sm transition-colors cursor-pointer",
                    if(field in @selected_wipe_fields,
                      do: "border-error/50 bg-error/10 text-error",
                      else:
                        "border-base-300 bg-base-200 text-base-content/70 hover:border-base-content/50"
                    )
                  ]}
                >
                  <.icon
                    name={
                      if field in @selected_wipe_fields,
                        do: "hero-check-circle",
                        else: "hero-minus-circle"
                    }
                    class="size-4"
                  />
                  {label}
                </button>
              </div>
            </div>

            <%!-- Security toggles --%>
            <div class="border-t-[0.5px] border-base-300 pt-5 space-y-4">
              <h3 class="text-sm font-semibold text-base-content/80">Security Options</h3>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div class="flex items-start gap-3">
                  <.input field={@form[:crypto_shred]} type="checkbox" label="Crypto Shred" />
                  <p class="text-xs text-base-content/50 mt-1">
                    Overwrites data with random bytes before nulling
                  </p>
                </div>
                <div>
                  <.input
                    field={@form[:auto_terminate_on_expiry]}
                    type="checkbox"
                    label="Auto-terminate on expiry"
                  />
                </div>
              </div>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <div>
                  <.input
                    field={@form[:retain_verdict]}
                    type="checkbox"
                    label="Retain Verdict (required)"
                  />
                </div>
                <div>
                  <.input
                    field={@form[:retain_audit]}
                    type="checkbox"
                    label="Retain Audit Trail (required)"
                  />
                </div>
              </div>
            </div>

            <%!-- Wipe preview --%>
            <div class="bg-base-200/50 border-[0.5px] border-base-300 rounded-lg p-4">
              <h4 class="text-xs font-medium text-base-content/70 uppercase tracking-wider mb-2">
                Wipe Behavior Preview
              </h4>
              <p class="text-sm text-base-content/80">
                When a session completes:
                <span :if={@selected_wipe_fields != []} class="text-error font-medium">
                  {Enum.join(@selected_wipe_fields, ", ")}
                </span>
                <span :if={@selected_wipe_fields == []} class="text-base-content/50">
                  (no fields selected)
                </span>
                will be
                <span
                  :if={@form[:crypto_shred].value == true or @form[:crypto_shred].value == "true"}
                  class="text-warning font-medium"
                >
                  crypto shredded and
                </span>
                wiped
                <span :if={@selected_strategy == "immediate"} class="text-error font-medium">
                  immediately
                </span>
                <span :if={@selected_strategy == "delayed"} class="text-warning font-medium">
                  after {@form[:wipe_delay_seconds].value || 0} seconds
                </span>
                <span :if={@selected_strategy == "scheduled"} class="text-info font-medium">
                  on schedule after {@form[:wipe_delay_seconds].value || 0} seconds
                </span>.
                Verdict and audit trail will be retained.
              </p>
            </div>

            <div class="flex items-center gap-4">
              <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
            </div>

            <div class="flex justify-end gap-3 pt-4 border-t-[0.5px] border-base-300">
              <.link
                patch={~p"/admin/ghost-protocol-configs"}
                class="inline-flex items-center h-[44px] px-6 rounded-lg border-[0.5px] border-base-300 text-sm text-base-content hover:bg-base-200 transition-colors"
              >
                Cancel
              </.link>
              <button
                type="submit"
                phx-disable-with="Saving..."
                class="inline-flex items-center h-[44px] px-6 rounded-lg bg-primary hover:bg-primary/80 text-white text-sm font-medium transition-colors"
              >
                <.icon name="hero-check" class="size-4 mr-2" />
                {if @live_action == :new, do: "Create Config", else: "Save Changes"}
              </button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Render: Index (list)
  # -------------------------------------------------------------------

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_ghost_protocol}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-base-content">
              <.icon name="hero-eye-slash" class="size-8 inline-block mr-1 text-error" />
              GhostProtocol Configs
            </h1>
            <p class="text-base-content/70 mt-1">
              {@total_count} config{if @total_count != 1, do: "s"} configured
            </p>
          </div>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "ghost_protocol:create")}
            patch={~p"/admin/ghost-protocol-configs/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-primary hover:bg-primary/80 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> New Config
          </.link>
        </div>

        <div
          :if={@total_count > 0}
          class="bg-base-100 border-[0.5px] border-base-300 rounded-lg overflow-hidden"
        >
          <div class="overflow-x-auto">
            <table class="w-full">
              <thead class="bg-base-200 border-b-[0.5px] border-base-300">
                <tr>
                  <th class="text-left px-6 py-3 text-xs font-medium text-base-content/70 uppercase tracking-wider">
                    Name
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-base-content/70 uppercase tracking-wider hidden sm:table-cell">
                    Strategy
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-base-content/70 uppercase tracking-wider hidden md:table-cell">
                    Crypto Shred
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-base-content/70 uppercase tracking-wider hidden lg:table-cell">
                    Workflows
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-base-content/70 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="text-right px-6 py-3 text-xs font-medium text-base-content/70 uppercase tracking-wider">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody id="ghost-protocol-configs-stream" phx-update="stream">
                <tr
                  :for={{dom_id, cfg} <- @streams.configs}
                  id={dom_id}
                  class={[
                    "border-b-[0.5px] border-base-300 transition-colors",
                    if(cfg.enabled,
                      do: "hover:bg-base-200/30",
                      else: "opacity-50 hover:bg-base-200/20"
                    )
                  ]}
                >
                  <td class="px-6 py-4">
                    <div class="font-medium text-sm text-base-content">{cfg.name}</div>
                    <div class="text-xs text-base-content/50">{cfg.slug}</div>
                  </td>
                  <td class="px-6 py-4 hidden sm:table-cell">
                    <.strategy_badge strategy={cfg.wipe_strategy} delay={cfg.wipe_delay_seconds} />
                  </td>
                  <td class="px-6 py-4 hidden md:table-cell">
                    <.crypto_shred_indicator enabled={cfg.crypto_shred} />
                  </td>
                  <td class="px-6 py-4 hidden lg:table-cell">
                    <span class="text-sm text-base-content/80">{length(cfg.workflows || [])}</span>
                  </td>
                  <td class="px-6 py-4">
                    <button
                      :if={AuthHooks.has_socket_permission?(assigns, "ghost_protocol:update")}
                      phx-click="toggle_enabled"
                      phx-value-id={cfg.id}
                      class="cursor-pointer"
                    >
                      <.enabled_badge enabled={cfg.enabled} />
                    </button>
                    <.enabled_badge
                      :if={!AuthHooks.has_socket_permission?(assigns, "ghost_protocol:update")}
                      enabled={cfg.enabled}
                    />
                  </td>
                  <td class="px-6 py-4 text-right">
                    <div class="flex items-center justify-end gap-2">
                      <.link
                        :if={AuthHooks.has_socket_permission?(assigns, "ghost_protocol:update")}
                        patch={~p"/admin/ghost-protocol-configs/#{cfg.id}/edit"}
                        class="inline-flex items-center h-[36px] px-4 text-sm rounded bg-base-200 hover:bg-base-300 text-base-content transition-colors"
                      >
                        <.icon name="hero-pencil" class="size-3.5" />
                      </.link>
                      <button
                        :if={AuthHooks.has_socket_permission?(assigns, "ghost_protocol:delete")}
                        phx-click="delete"
                        phx-value-id={cfg.id}
                        data-confirm={"Delete config \"#{cfg.name}\"? This cannot be undone."}
                        class="inline-flex items-center h-[36px] px-4 text-sm rounded border-[0.5px] border-error/30 text-error hover:bg-error/10 transition-colors"
                      >
                        <.icon name="hero-trash" class="size-3.5" />
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div
          :if={@total_count == 0}
          id="ghost-protocol-configs-empty"
          class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-12 text-center"
        >
          <.icon name="hero-eye-slash" class="size-12 mx-auto text-base-content/30 mb-4" />
          <p class="text-base-content/70 mb-4">No GhostProtocol configs</p>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "ghost_protocol:create")}
            patch={~p"/admin/ghost-protocol-configs/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-primary hover:bg-primary/80 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> Create First Config
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Badge components
  # -------------------------------------------------------------------

  attr :strategy, :atom, required: true
  attr :delay, :integer, default: 0

  defp strategy_badge(%{strategy: :immediate} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-error/20 text-error">
      Immediate
    </span>
    """
  end

  defp strategy_badge(%{strategy: :delayed} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-warning/20 text-warning">
      Delayed ({@delay}s)
    </span>
    """
  end

  defp strategy_badge(%{strategy: :scheduled} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-info/20 text-info">
      Scheduled ({@delay}s)
    </span>
    """
  end

  defp strategy_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-base-content/10 text-base-content/70">
      {to_string(@strategy)}
    </span>
    """
  end

  attr :enabled, :boolean, required: true

  defp crypto_shred_indicator(%{enabled: true} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 text-sm text-warning">
      <.icon name="hero-shield-check" class="size-4" /> Active
    </span>
    """
  end

  defp crypto_shred_indicator(assigns) do
    ~H"""
    <span class="text-sm text-base-content/50">&mdash;</span>
    """
  end

  defp enabled_badge(%{enabled: true} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-success/20 text-success">
      <.icon name="hero-check-circle" class="size-3" /> Enabled
    </span>
    """
  end

  defp enabled_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-base-content/10 text-base-content/70">
      <.icon name="hero-x-circle" class="size-3" /> Disabled
    </span>
    """
  end
end
