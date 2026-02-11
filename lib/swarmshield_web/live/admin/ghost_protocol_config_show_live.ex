defmodule SwarmshieldWeb.Admin.GhostProtocolConfigShowLive do
  @moduledoc """
  Detail view for a specific GhostProtocol config.
  Shows settings, linked workflows, wipe history, and emergency force-wipe.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.GhostProtocol
  alias SwarmshieldWeb.Hooks.AuthHooks

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "GhostProtocol Config")}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "ghost_protocol:view") do
      workspace_id = socket.assigns.current_workspace.id
      config = GhostProtocol.get_config_for_workspace!(id, workspace_id)

      {:noreply,
       socket
       |> assign(:page_title, config.name)
       |> assign(:config, config)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view GhostProtocol configs.")
       |> redirect(to: ~p"/select-workspace")}
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
      active_nav={:admin_ghost_protocol}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-base-content">
              <.icon name="hero-eye-slash" class="size-8 inline-block mr-1 text-error" />
              {@config.name}
            </h1>
            <p class="text-base-content/70 mt-1">{@config.slug}</p>
          </div>
          <div class="flex items-center gap-3">
            <.link
              :if={AuthHooks.has_socket_permission?(assigns, "ghost_protocol:update")}
              patch={~p"/admin/ghost-protocol-configs/#{@config.id}/edit"}
              class="inline-flex items-center gap-2 h-[44px] px-4 rounded-lg border-[0.5px] border-base-300 text-sm text-base-content hover:bg-base-200 transition-colors"
            >
              <.icon name="hero-pencil" class="size-4" /> Edit
            </.link>
            <.link
              patch={~p"/admin/ghost-protocol-configs"}
              class="inline-flex items-center gap-2 h-[44px] px-4 rounded-lg border-[0.5px] border-base-300 text-sm text-base-content hover:bg-base-200 transition-colors"
            >
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </.link>
          </div>
        </div>

        <%!-- Config details --%>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-6 space-y-4">
            <h2 class="text-lg font-semibold text-base-content">Wipe Configuration</h2>
            <dl class="space-y-3">
              <div class="flex justify-between">
                <dt class="text-sm text-base-content/70">Strategy</dt>
                <dd class="text-sm text-base-content font-medium">
                  {to_string(@config.wipe_strategy) |> String.capitalize()}
                </dd>
              </div>
              <div :if={@config.wipe_strategy in [:delayed, :scheduled]} class="flex justify-between">
                <dt class="text-sm text-base-content/70">Delay</dt>
                <dd class="text-sm text-base-content">{@config.wipe_delay_seconds}s</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-sm text-base-content/70">Crypto Shred</dt>
                <dd class="text-sm">
                  <span :if={@config.crypto_shred} class="text-warning">Active</span>
                  <span :if={!@config.crypto_shred} class="text-base-content/50">Inactive</span>
                </dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-sm text-base-content/70">Wipe Fields</dt>
                <dd class="text-sm text-base-content">
                  {Enum.join(@config.wipe_fields || [], ", ")}
                </dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-sm text-base-content/70">Max Duration</dt>
                <dd class="text-sm text-base-content">{@config.max_session_duration_seconds}s</dd>
              </div>
            </dl>
          </div>

          <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-6 space-y-4">
            <h2 class="text-lg font-semibold text-base-content">Linked Workflows</h2>
            <div :if={(@config.workflows || []) == []} class="text-sm text-base-content/50">
              No workflows use this config
            </div>
            <ul :if={(@config.workflows || []) != []} class="space-y-2">
              <li :for={workflow <- @config.workflows || []} class="text-sm text-base-content/80">
                {workflow.name}
              </li>
            </ul>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
