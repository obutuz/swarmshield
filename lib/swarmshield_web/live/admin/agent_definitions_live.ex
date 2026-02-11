defmodule SwarmshieldWeb.Admin.AgentDefinitionsLive do
  @moduledoc """
  Admin CRUD for AI agent definitions (Opus 4.6 personas used in deliberation).

  Features expertise tag input, system prompt with character count,
  model select from approved list, temperature slider, workspace-scoped.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Agents
  alias Swarmshield.Deliberation.AgentDefinition
  alias SwarmshieldWeb.Hooks.AuthHooks

  @model_options Enum.map(AgentDefinition.approved_models(), fn m ->
                   label =
                     m
                     |> String.replace("claude-", "")
                     |> String.split("-")
                     |> Enum.map_join(" ", &String.capitalize/1)

                   {"Claude #{label}", m}
                 end)

  # -------------------------------------------------------------------
  # Mount
  # -------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Agent Definitions")}
  end

  # -------------------------------------------------------------------
  # Handle params
  # -------------------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "agents:view") do
      {:noreply, apply_action(socket, socket.assigns.live_action, params)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to manage agent definitions.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  defp apply_action(socket, :index, _params) do
    workspace_id = socket.assigns.current_workspace.id
    {definitions, total_count} = Agents.list_agent_definitions(workspace_id)

    socket
    |> assign(:page_title, "Agent Definitions")
    |> assign(:total_count, total_count)
    |> assign(:definition, nil)
    |> assign(:form, nil)
    |> assign(:expertise_text, "")
    |> stream(:definitions, definitions, reset: true)
  end

  defp apply_action(socket, :new, _params) do
    definition = %AgentDefinition{temperature: 0.3, max_tokens: 4096, model: "claude-opus-4-6"}
    changeset = Agents.change_agent_definition(definition)

    socket
    |> assign(:page_title, "New Agent Definition")
    |> assign(:definition, definition)
    |> assign(:form, to_form(changeset))
    |> assign(:expertise_text, "")
    |> assign(:prompt_char_count, 0)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    workspace_id = socket.assigns.current_workspace.id
    definition = Agents.get_agent_definition_for_workspace!(id, workspace_id)
    changeset = Agents.change_agent_definition(definition)

    expertise_text = Enum.join(definition.expertise || [], ", ")
    prompt_len = String.length(definition.system_prompt || "")

    socket
    |> assign(:page_title, "Edit Agent Definition")
    |> assign(:definition, definition)
    |> assign(:form, to_form(changeset))
    |> assign(:expertise_text, expertise_text)
    |> assign(:prompt_char_count, prompt_len)
  end

  # -------------------------------------------------------------------
  # Events: Form validate + submit
  # -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"agent_definition" => params}, socket) do
    prompt_len = String.length(params["system_prompt"] || "")

    changeset =
      (socket.assigns.definition || %AgentDefinition{})
      |> Agents.change_agent_definition(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:prompt_char_count, prompt_len)}
  end

  def handle_event("save", %{"agent_definition" => params}, socket) do
    params = enrich_expertise(params, socket)

    case socket.assigns.live_action do
      :new -> create_definition(socket, params)
      :edit -> update_definition(socket, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "agents:delete") do
      delete_verified_definition(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "agents:update") do
      toggle_verified_definition(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("update_expertise", %{"value" => value}, socket) do
    {:noreply, assign(socket, :expertise_text, value)}
  end

  # -------------------------------------------------------------------
  # Private: mutations
  # -------------------------------------------------------------------

  defp create_definition(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "agents:create") do
      workspace_id = socket.assigns.current_workspace.id

      case Agents.create_agent_definition(workspace_id, params) do
        {:ok, _definition} ->
          {:noreply,
           socket
           |> put_flash(:info, "Agent definition created.")
           |> push_patch(to: ~p"/admin/agent-definitions")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp update_definition(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "agents:update") do
      definition = socket.assigns.definition

      case Agents.update_agent_definition(definition, params) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "Agent definition updated.")
           |> push_patch(to: ~p"/admin/agent-definitions")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp delete_verified_definition(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    definition = Agents.get_agent_definition_for_workspace!(id, workspace_id)

    case Agents.delete_agent_definition(definition) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> stream_delete(:definitions, definition)
         |> update(:total_count, &max(&1 - 1, 0))
         |> put_flash(:info, "Agent definition deleted.")}

      {:error, :has_workflow_steps} ->
        {:noreply,
         put_flash(socket, :error, "Cannot delete — definition is used in workflow steps.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete agent definition.")}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Definition not found.")}
  end

  defp toggle_verified_definition(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    definition = Agents.get_agent_definition_for_workspace!(id, workspace_id)

    case Agents.update_agent_definition(definition, %{enabled: !definition.enabled}) do
      {:ok, updated} ->
        {:noreply, stream_insert(socket, :definitions, updated)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update definition.")}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Definition not found.")}
  end

  # -------------------------------------------------------------------
  # Private: expertise enrichment
  # -------------------------------------------------------------------

  defp enrich_expertise(params, socket) do
    expertise =
      socket.assigns.expertise_text
      |> String.split(~r/[,\n]/)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Map.put(params, "expertise", expertise)
  end

  # -------------------------------------------------------------------
  # Render: Create / Edit form
  # -------------------------------------------------------------------

  @impl true
  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    assigns = assign(assigns, :model_options, @model_options)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_agent_definitions}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-gray-100">
              {if @live_action == :new, do: "New Agent Definition", else: "Edit Agent Definition"}
            </h1>
            <p class="text-gray-400 mt-1">Configure an AI persona for deliberation analysis</p>
          </div>
          <.link
            patch={~p"/admin/agent-definitions"}
            class="inline-flex items-center gap-2 h-[44px] px-4 rounded-lg border border-gray-600 text-sm text-gray-100 hover:bg-gray-800 transition-colors"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to Definitions
          </.link>
        </div>

        <div class="bg-gray-800 border border-gray-700 rounded-lg p-6">
          <.form
            for={@form}
            id="agent-definition-form"
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
                  placeholder="e.g. Security Analyst"
                />
              </div>
              <div>
                <.input
                  field={@form[:role]}
                  type="text"
                  label="Role"
                  phx-debounce="300"
                  required
                  placeholder="e.g. security_analyst"
                />
              </div>
            </div>

            <div>
              <.input
                field={@form[:description]}
                type="textarea"
                label="Description"
                phx-debounce="300"
                rows="2"
                placeholder="Brief description of this agent's purpose..."
              />
            </div>

            <%!-- Expertise tags --%>
            <div class="space-y-1">
              <label class="block text-sm font-medium text-gray-300">
                Expertise (comma separated)
              </label>
              <textarea
                phx-blur="update_expertise"
                phx-debounce="300"
                rows="2"
                placeholder="threat detection, prompt injection, data privacy"
                class="w-full bg-gray-900 border border-gray-600 rounded-lg text-gray-100 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 px-3 py-2"
              >{@expertise_text}</textarea>
              <div :if={@expertise_text != ""} class="flex flex-wrap gap-1.5 mt-2">
                <span
                  :for={tag <- parse_tags(@expertise_text)}
                  class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-400/20 text-blue-400"
                >
                  {tag}
                </span>
              </div>
            </div>

            <%!-- System prompt --%>
            <div class="space-y-1">
              <.input
                field={@form[:system_prompt]}
                type="textarea"
                label="System Prompt"
                phx-debounce="300"
                rows="8"
                required
                placeholder="You are a security analyst specializing in..."
              />
              <p class="text-xs text-gray-500 text-right">
                {@prompt_char_count} / 102,400 characters
              </p>
            </div>

            <%!-- Model, temperature, max_tokens --%>
            <div class="grid grid-cols-1 sm:grid-cols-3 gap-5">
              <div>
                <.input
                  field={@form[:model]}
                  type="select"
                  label="Model"
                  options={@model_options}
                  phx-debounce="300"
                />
              </div>
              <div class="space-y-1">
                <.input
                  field={@form[:temperature]}
                  type="number"
                  label="Temperature"
                  step="0.05"
                  min="0"
                  max="1"
                  phx-debounce="300"
                />
                <p class="text-xs text-gray-500">0 = deterministic, 1 = creative</p>
              </div>
              <div>
                <.input
                  field={@form[:max_tokens]}
                  type="number"
                  label="Max Tokens"
                  min="1"
                  max="32768"
                  step="256"
                  phx-debounce="300"
                />
              </div>
            </div>

            <div class="flex items-center gap-4">
              <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
            </div>

            <div class="flex justify-end gap-3 pt-4 border-t border-gray-700">
              <.link
                patch={~p"/admin/agent-definitions"}
                class="inline-flex items-center h-[44px] px-6 rounded-lg border border-gray-600 text-sm text-gray-100 hover:bg-gray-700 transition-colors"
              >
                Cancel
              </.link>
              <button
                type="submit"
                phx-disable-with="Saving..."
                class="inline-flex items-center h-[44px] px-6 rounded-lg bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium transition-colors"
              >
                <.icon name="hero-check" class="size-4 mr-2" />
                {if @live_action == :new, do: "Create Definition", else: "Save Changes"}
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
      active_nav={:admin_agent_definitions}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-gray-100">
              <.icon name="hero-cpu-chip" class="size-8 inline-block mr-1 text-blue-400" />
              Agent Definitions
            </h1>
            <p class="text-gray-400 mt-1">
              {@total_count} definition{if @total_count != 1, do: "s"} configured
            </p>
          </div>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "agents:create")}
            patch={~p"/admin/agent-definitions/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> New Definition
          </.link>
        </div>

        <div
          :if={@total_count > 0}
          class="bg-gray-800 border border-gray-700 rounded-lg overflow-hidden"
        >
          <div class="overflow-x-auto">
            <table class="w-full">
              <thead class="bg-gray-900 border-b border-gray-700">
                <tr>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider">
                    Name
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider hidden sm:table-cell">
                    Role
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider hidden md:table-cell">
                    Model
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider hidden lg:table-cell">
                    Temperature
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="text-right px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody id="agent-definitions-stream" phx-update="stream">
                <tr
                  :for={{dom_id, defn} <- @streams.definitions}
                  id={dom_id}
                  class={[
                    "border-b border-gray-700 transition-colors",
                    if(defn.enabled,
                      do: "hover:bg-gray-800/50",
                      else: "opacity-50 hover:bg-gray-800/30"
                    )
                  ]}
                >
                  <td class="px-6 py-4">
                    <div class="font-medium text-sm text-gray-100">{defn.name}</div>
                    <div
                      :if={defn.description}
                      class="text-xs text-gray-500 truncate max-w-[200px]"
                    >
                      {defn.description}
                    </div>
                  </td>
                  <td class="px-6 py-4 hidden sm:table-cell">
                    <span class="text-sm text-gray-300">{defn.role}</span>
                  </td>
                  <td class="px-6 py-4 hidden md:table-cell">
                    <.model_badge model={defn.model} />
                  </td>
                  <td class="px-6 py-4 hidden lg:table-cell">
                    <span class="text-sm text-gray-300">{defn.temperature}</span>
                  </td>
                  <td class="px-6 py-4">
                    <button
                      :if={AuthHooks.has_socket_permission?(assigns, "agents:update")}
                      phx-click="toggle_enabled"
                      phx-value-id={defn.id}
                      class="cursor-pointer"
                    >
                      <.enabled_badge enabled={defn.enabled} />
                    </button>
                    <.enabled_badge
                      :if={!AuthHooks.has_socket_permission?(assigns, "agents:update")}
                      enabled={defn.enabled}
                    />
                  </td>
                  <td class="px-6 py-4 text-right">
                    <div class="flex items-center justify-end gap-2">
                      <.link
                        :if={AuthHooks.has_socket_permission?(assigns, "agents:update")}
                        patch={~p"/admin/agent-definitions/#{defn.id}/edit"}
                        class="inline-flex items-center h-[36px] px-4 text-sm rounded bg-gray-700 hover:bg-gray-600 text-gray-100 transition-colors"
                      >
                        <.icon name="hero-pencil" class="size-3.5" />
                      </.link>
                      <button
                        :if={AuthHooks.has_socket_permission?(assigns, "agents:delete")}
                        phx-click="delete"
                        phx-value-id={defn.id}
                        data-confirm={"Delete agent \"#{defn.name}\"? This cannot be undone."}
                        class="inline-flex items-center h-[36px] px-4 text-sm rounded border border-red-400/30 text-red-400 hover:bg-red-400/10 transition-colors"
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
          id="agent-definitions-empty"
          class="bg-gray-800 border border-gray-700 rounded-lg p-12 text-center"
        >
          <.icon name="hero-cpu-chip" class="size-12 mx-auto text-gray-600 mb-4" />
          <p class="text-gray-400 mb-4">No agent definitions configured</p>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "agents:create")}
            patch={~p"/admin/agent-definitions/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> Create First Definition
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Private: tag parsing
  # -------------------------------------------------------------------

  defp parse_tags(text) when is_binary(text) do
    text
    |> String.split(~r/[,\n]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # -------------------------------------------------------------------
  # Badge components
  # -------------------------------------------------------------------

  attr :model, :string, required: true

  defp model_badge(assigns) do
    label =
      case assigns.model do
        "claude-opus-4-6" -> "Opus 4.6"
        "claude-sonnet-4-5-20250929" -> "Sonnet 4.5"
        "claude-haiku-4-5-20251001" -> "Haiku 4.5"
        other -> other
      end

    assigns = assign(assigns, :label, label)

    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-purple-400/20 text-purple-400">
      {@label}
    </span>
    """
  end

  attr :enabled, :boolean, required: true

  defp enabled_badge(%{enabled: true} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-400/20 text-green-400">
      <.icon name="hero-check-circle" class="size-3" /> Enabled
    </span>
    """
  end

  defp enabled_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-400/20 text-gray-400">
      <.icon name="hero-x-circle" class="size-3" /> Disabled
    </span>
    """
  end
end
