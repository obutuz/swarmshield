defmodule SwarmshieldWeb.Admin.SettingsLive do
  @moduledoc """
  Workspace settings admin view.

  Sections: General (name, description), Deliberation defaults,
  API key management with secure regeneration.
  All settings stored in workspace.settings map.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Accounts
  alias SwarmshieldWeb.Hooks.AuthHooks

  # -------------------------------------------------------------------
  # Mount
  # -------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Workspace Settings")}
  end

  # -------------------------------------------------------------------
  # Handle params
  # -------------------------------------------------------------------

  @impl true
  def handle_params(_params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "settings:view") do
      workspace = socket.assigns.current_workspace
      settings = workspace.settings || %{}

      changeset = Accounts.change_workspace(workspace)

      {:noreply,
       socket
       |> assign(:page_title, "Workspace Settings")
       |> assign(:workspace, workspace)
       |> assign(:form, to_form(changeset))
       |> assign(:settings, settings)
       |> assign(:default_timeout, settings["default_timeout_seconds"] || 300)
       |> assign(:max_rounds, settings["max_deliberation_rounds"] || 3)
       |> assign(:newly_generated_key, nil)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view workspace settings.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  # -------------------------------------------------------------------
  # Events
  # -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"workspace" => params}, socket) do
    changeset =
      socket.assigns.workspace
      |> Accounts.change_workspace(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save_general", %{"workspace" => params}, socket) do
    if AuthHooks.has_socket_permission?(socket, "settings:update") do
      save_workspace(socket, params)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event(
        "save_settings",
        %{"default_timeout" => timeout, "max_rounds" => rounds},
        socket
      ) do
    if AuthHooks.has_socket_permission?(socket, "settings:update") do
      save_deliberation_settings(socket, timeout, rounds)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("regenerate_api_key", _params, socket) do
    if AuthHooks.has_socket_permission?(socket, "settings:update") do
      regenerate_key(socket)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("dismiss_key", _params, socket) do
    {:noreply, assign(socket, :newly_generated_key, nil)}
  end

  # -------------------------------------------------------------------
  # Private: mutations
  # -------------------------------------------------------------------

  defp save_workspace(socket, params) do
    workspace = socket.assigns.workspace

    case Accounts.update_workspace(workspace, params) do
      {:ok, updated} ->
        changeset = Accounts.change_workspace(updated)

        {:noreply,
         socket
         |> assign(:workspace, updated)
         |> assign(:form, to_form(changeset))
         |> put_flash(:info, "Workspace settings saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save_deliberation_settings(socket, timeout_str, rounds_str) do
    workspace = socket.assigns.workspace
    timeout = parse_integer(timeout_str, 300)
    rounds = parse_integer(rounds_str, 3)

    current_settings = workspace.settings || %{}

    new_settings =
      Map.merge(current_settings, %{
        "default_timeout_seconds" => timeout,
        "max_deliberation_rounds" => rounds
      })

    case Accounts.update_workspace(workspace, %{settings: new_settings}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:workspace, updated)
         |> assign(:settings, updated.settings)
         |> assign(:default_timeout, timeout)
         |> assign(:max_rounds, rounds)
         |> put_flash(:info, "Deliberation settings saved.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save settings.")}
    end
  end

  defp regenerate_key(socket) do
    workspace = socket.assigns.workspace

    case Accounts.generate_workspace_api_key(workspace) do
      {:ok, {raw_key, updated}} ->
        {:noreply,
         socket
         |> assign(:workspace, updated)
         |> assign(:newly_generated_key, raw_key)
         |> put_flash(:info, "API key regenerated. Copy it now — it won't be shown again.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not regenerate API key.")}
    end
  end

  defp parse_integer(str, default) when is_binary(str) do
    case Integer.parse(str) do
      {val, _} -> val
      :error -> default
    end
  end

  defp parse_integer(_, default), do: default

  # -------------------------------------------------------------------
  # Render
  # -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_settings}
    >
      <div class="space-y-6">
        <div>
          <h1 class="text-3xl font-bold text-base-content">
            <.icon name="hero-cog-6-tooth" class="size-8 inline-block mr-1 text-info" />
            Workspace Settings
          </h1>
          <p class="text-base-content/70 mt-1">Configure workspace preferences and API access</p>
        </div>

        <%!-- General settings --%>
        <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-6">
          <h2 class="text-lg font-semibold text-base-content mb-4">General</h2>
          <.form
            for={@form}
            id="workspace-settings-form"
            phx-change="validate"
            phx-submit="save_general"
            class="space-y-4"
          >
            <div class="grid grid-cols-1 md:grid-cols-2 gap-5">
              <div>
                <.input
                  field={@form[:name]}
                  type="text"
                  label="Workspace Name"
                  phx-debounce="300"
                  required
                />
              </div>
              <div>
                <.input
                  field={@form[:slug]}
                  type="text"
                  label="Slug"
                  phx-debounce="300"
                  required
                />
              </div>
            </div>
            <div>
              <.input
                field={@form[:description]}
                type="textarea"
                label="Description"
                phx-debounce="300"
                rows="3"
              />
            </div>
            <div class="flex justify-end pt-2">
              <button
                :if={AuthHooks.has_socket_permission?(assigns, "settings:update")}
                type="submit"
                phx-disable-with="Saving..."
                class="inline-flex items-center h-[44px] px-6 rounded-lg bg-primary hover:bg-primary/80 text-white text-sm font-medium transition-colors"
              >
                Save General Settings
              </button>
            </div>
          </.form>
        </div>

        <%!-- Deliberation settings --%>
        <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-6">
          <h2 class="text-lg font-semibold text-base-content mb-4">Deliberation Defaults</h2>
          <form
            id="deliberation-settings-form"
            phx-submit="save_settings"
            class="space-y-4"
          >
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-5">
              <div>
                <label class="block text-sm font-medium text-base-content/80 mb-1">
                  Default Timeout (seconds)
                </label>
                <input
                  type="number"
                  name="default_timeout"
                  value={@default_timeout}
                  min="30"
                  max="3600"
                  phx-debounce="300"
                  class="w-full h-[44px] bg-base-200 border-[0.5px] border-base-300 rounded-lg text-base-content focus:border-primary focus:ring-1 focus:ring-primary px-3"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-base-content/80 mb-1">
                  Max Deliberation Rounds
                </label>
                <input
                  type="number"
                  name="max_rounds"
                  value={@max_rounds}
                  min="1"
                  max="10"
                  phx-debounce="300"
                  class="w-full h-[44px] bg-base-200 border-[0.5px] border-base-300 rounded-lg text-base-content focus:border-primary focus:ring-1 focus:ring-primary px-3"
                />
              </div>
            </div>
            <div class="flex justify-end pt-2">
              <button
                :if={AuthHooks.has_socket_permission?(assigns, "settings:update")}
                type="submit"
                phx-disable-with="Saving..."
                class="inline-flex items-center h-[44px] px-6 rounded-lg bg-primary hover:bg-primary/80 text-white text-sm font-medium transition-colors"
              >
                Save Deliberation Settings
              </button>
            </div>
          </form>
        </div>

        <%!-- API Key management --%>
        <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-6">
          <h2 class="text-lg font-semibold text-base-content mb-4">API Key</h2>

          <div class="space-y-4">
            <div class="flex items-center gap-4">
              <div>
                <p class="text-sm text-base-content/80">Current key prefix:</p>
                <p class="text-sm font-mono text-base-content/70">
                  {@workspace.api_key_prefix || "Not generated"}...
                </p>
              </div>
            </div>

            <%!-- Newly generated key display --%>
            <div
              :if={@newly_generated_key}
              class="bg-success/10 border-[0.5px] border-success/30 rounded-lg p-4 space-y-2"
            >
              <div class="flex items-center gap-2">
                <.icon name="hero-key" class="size-5 text-success" />
                <p class="text-sm font-medium text-success">
                  New API key generated — copy it now!
                </p>
              </div>
              <div class="flex items-center gap-2">
                <code class="flex-1 text-sm font-mono text-base-content bg-base-200 rounded px-3 py-2 break-all">
                  {@newly_generated_key}
                </code>
              </div>
              <p class="text-xs text-base-content/50">
                This key will not be shown again. Store it securely.
              </p>
              <button
                type="button"
                phx-click="dismiss_key"
                class="text-xs text-base-content/70 hover:text-base-content/80 transition-colors"
              >
                Dismiss
              </button>
            </div>

            <div class="flex justify-end pt-2">
              <button
                :if={AuthHooks.has_socket_permission?(assigns, "settings:update")}
                type="button"
                phx-click="regenerate_api_key"
                data-confirm="Regenerate API key? The current key will be immediately invalidated. All API requests using the old key will be rejected."
                class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg border-[0.5px] border-error/30 text-error hover:bg-error/10 text-sm font-medium transition-colors"
              >
                <.icon name="hero-arrow-path" class="size-4" /> Regenerate API Key
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
