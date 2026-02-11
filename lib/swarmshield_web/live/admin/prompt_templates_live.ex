defmodule SwarmshieldWeb.Admin.PromptTemplatesLive do
  @moduledoc """
  Admin CRUD for prompt templates with variable interpolation preview.

  Live variable extraction from {{variable}} syntax. Preview panel
  renders template with sample values. Version auto-incremented on
  template text changes.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Agents
  alias Swarmshield.Deliberation.PromptTemplate
  alias SwarmshieldWeb.Hooks.AuthHooks

  @category_options [
    {"Analysis", "analysis"},
    {"Summary", "summary"},
    {"Evaluation", "evaluation"},
    {"Debate", "debate"},
    {"Custom", "custom"}
  ]

  # -------------------------------------------------------------------
  # Mount
  # -------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Prompt Templates")}
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
       |> put_flash(:error, "You are not authorized to manage prompt templates.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  defp apply_action(socket, :index, _params) do
    workspace_id = socket.assigns.current_workspace.id
    {templates, total_count} = Agents.list_prompt_templates(workspace_id)

    socket
    |> assign(:page_title, "Prompt Templates")
    |> assign(:total_count, total_count)
    |> assign(:template, nil)
    |> assign(:form, nil)
    |> stream(:templates, templates, reset: true)
  end

  defp apply_action(socket, :new, _params) do
    template = %PromptTemplate{}
    changeset = Agents.change_prompt_template(template)

    socket
    |> assign(:page_title, "New Prompt Template")
    |> assign(:template, template)
    |> assign(:form, to_form(changeset))
    |> assign(:detected_variables, [])
    |> assign(:preview_values, %{})
    |> assign(:preview_output, nil)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    workspace_id = socket.assigns.current_workspace.id
    template = Agents.get_prompt_template_for_workspace!(id, workspace_id)
    changeset = Agents.change_prompt_template(template)

    variables = PromptTemplate.extract_variables(template.template || "")

    socket
    |> assign(:page_title, "Edit Prompt Template")
    |> assign(:template, template)
    |> assign(:form, to_form(changeset))
    |> assign(:detected_variables, variables)
    |> assign(:preview_values, %{})
    |> assign(:preview_output, nil)
  end

  # -------------------------------------------------------------------
  # Events: Form validate + submit
  # -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"prompt_template" => params}, socket) do
    template_text = params["template"] || ""
    variables = PromptTemplate.extract_variables(template_text)

    changeset =
      (socket.assigns.template || %PromptTemplate{})
      |> Agents.change_prompt_template(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:detected_variables, variables)}
  end

  def handle_event("save", %{"prompt_template" => params}, socket) do
    case socket.assigns.live_action do
      :new -> create_template(socket, params)
      :edit -> update_template(socket, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "agents:delete") do
      delete_verified_template(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "agents:update") do
      toggle_verified_template(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("update_preview_value", %{"variable" => var, "value" => val}, socket) do
    new_values = Map.put(socket.assigns.preview_values, var, val)
    template_text = get_current_template_text(socket)
    preview_output = render_preview(template_text, new_values)

    {:noreply,
     socket
     |> assign(:preview_values, new_values)
     |> assign(:preview_output, preview_output)}
  end

  # -------------------------------------------------------------------
  # Private: mutations
  # -------------------------------------------------------------------

  defp create_template(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "agents:create") do
      workspace_id = socket.assigns.current_workspace.id

      case Agents.create_prompt_template(workspace_id, params) do
        {:ok, _template} ->
          {:noreply,
           socket
           |> put_flash(:info, "Prompt template created.")
           |> push_patch(to: ~p"/admin/prompt-templates")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp update_template(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "agents:update") do
      template = socket.assigns.template

      case Agents.update_prompt_template(template, params) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "Prompt template updated.")
           |> push_patch(to: ~p"/admin/prompt-templates")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp delete_verified_template(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    template = Agents.get_prompt_template_for_workspace!(id, workspace_id)

    case Agents.delete_prompt_template(template) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> stream_delete(:templates, template)
         |> update(:total_count, &max(&1 - 1, 0))
         |> put_flash(:info, "Prompt template deleted.")}

      {:error, :has_workflow_steps} ->
        {:noreply,
         put_flash(socket, :error, "Cannot delete — template is used in workflow steps.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete prompt template.")}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Template not found.")}
  end

  defp toggle_verified_template(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    template = Agents.get_prompt_template_for_workspace!(id, workspace_id)

    case Agents.update_prompt_template(template, %{enabled: !template.enabled}) do
      {:ok, updated} ->
        {:noreply, stream_insert(socket, :templates, updated)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update template.")}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Template not found.")}
  end

  # -------------------------------------------------------------------
  # Private: preview
  # -------------------------------------------------------------------

  defp get_current_template_text(socket) do
    case socket.assigns.form do
      %{source: %{changes: %{template: t}}} -> t
      _ -> (socket.assigns.template && socket.assigns.template.template) || ""
    end
  end

  defp render_preview("", _values), do: nil
  defp render_preview(nil, _values), do: nil

  defp render_preview(template_text, values) when is_binary(template_text) do
    PromptTemplate.render(template_text, values)
  end

  # -------------------------------------------------------------------
  # Render: Create / Edit form
  # -------------------------------------------------------------------

  @impl true
  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    assigns = assign(assigns, :category_options, @category_options)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_prompt_templates}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-gray-100">
              {if @live_action == :new, do: "New Prompt Template", else: "Edit Prompt Template"}
            </h1>
            <p class="text-gray-400 mt-1">Configure a template for agent deliberation prompts</p>
          </div>
          <.link
            patch={~p"/admin/prompt-templates"}
            class="inline-flex items-center gap-2 h-[44px] px-4 rounded-lg border border-gray-600 text-sm text-gray-100 hover:bg-gray-800 transition-colors"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to Templates
          </.link>
        </div>

        <div class="bg-gray-800 border border-gray-700 rounded-lg p-6">
          <.form
            for={@form}
            id="prompt-template-form"
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
                  placeholder="e.g. Security Analysis Prompt"
                />
              </div>
              <div>
                <.input
                  field={@form[:category]}
                  type="select"
                  label="Category"
                  options={@category_options}
                  phx-debounce="300"
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
                placeholder="Brief description of when this template is used..."
              />
            </div>

            <div>
              <.input
                field={@form[:template]}
                type="textarea"
                label="Template"
                phx-debounce="300"
                rows="10"
                required
                placeholder="You are analyzing a {{event_type}} event.&#10;&#10;Content: {{content}}&#10;&#10;Provide your analysis..."
              />
              <p class="text-xs text-gray-500 mt-1">
                Use {"{{variable_name}}"} syntax for dynamic content injection.
              </p>
            </div>

            <%!-- Detected variables --%>
            <div :if={@detected_variables != []} class="space-y-2">
              <h3 class="text-sm font-semibold text-gray-300">
                Detected Variables ({length(@detected_variables)})
              </h3>
              <div class="flex flex-wrap gap-1.5">
                <span
                  :for={var <- @detected_variables}
                  class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-400/20 text-blue-400"
                >
                  {"{{#{var}}}"}
                </span>
              </div>
            </div>

            <%!-- Preview panel --%>
            <div
              :if={@detected_variables != []}
              class="border-t border-gray-700 pt-5 space-y-4"
            >
              <h3 class="text-sm font-semibold text-gray-300">Preview</h3>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div :for={var <- @detected_variables}>
                  <label class="block text-xs font-medium text-gray-400 mb-1">{var}</label>
                  <input
                    type="text"
                    phx-blur="update_preview_value"
                    phx-value-variable={var}
                    phx-debounce="300"
                    placeholder={"Sample #{var} value..."}
                    value={Map.get(@preview_values, var, "")}
                    class="w-full h-[36px] bg-gray-900 border border-gray-600 rounded-lg text-gray-100 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 px-3 text-sm"
                  />
                </div>
              </div>
              <div :if={@preview_output} class="bg-gray-900 border border-gray-600 rounded-lg p-4">
                <label class="block text-xs font-medium text-gray-400 mb-2">Rendered Output</label>
                <pre class="text-sm text-gray-100 whitespace-pre-wrap font-mono">{@preview_output}</pre>
              </div>
            </div>

            <div class="flex items-center gap-4">
              <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
              <span :if={@template && @template.id} class="text-xs text-gray-500">
                Version: {@template.version || 1}
              </span>
            </div>

            <div class="flex justify-end gap-3 pt-4 border-t border-gray-700">
              <.link
                patch={~p"/admin/prompt-templates"}
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
                {if @live_action == :new, do: "Create Template", else: "Save Changes"}
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
      active_nav={:admin_prompt_templates}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-gray-100">
              <.icon
                name="hero-document-text"
                class="size-8 inline-block mr-1 text-blue-400"
              /> Prompt Templates
            </h1>
            <p class="text-gray-400 mt-1">
              {@total_count} template{if @total_count != 1, do: "s"} configured
            </p>
          </div>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "agents:create")}
            patch={~p"/admin/prompt-templates/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> New Template
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
                    Category
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider hidden md:table-cell">
                    Variables
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider hidden lg:table-cell">
                    Version
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="text-right px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody id="prompt-templates-stream" phx-update="stream">
                <tr
                  :for={{dom_id, tmpl} <- @streams.templates}
                  id={dom_id}
                  class={[
                    "border-b border-gray-700 transition-colors",
                    if(tmpl.enabled,
                      do: "hover:bg-gray-800/50",
                      else: "opacity-50 hover:bg-gray-800/30"
                    )
                  ]}
                >
                  <td class="px-6 py-4">
                    <div class="font-medium text-sm text-gray-100">{tmpl.name}</div>
                    <div
                      :if={tmpl.description}
                      class="text-xs text-gray-500 truncate max-w-[200px]"
                    >
                      {tmpl.description}
                    </div>
                  </td>
                  <td class="px-6 py-4 hidden sm:table-cell">
                    <span :if={tmpl.category} class="text-sm text-gray-300">{tmpl.category}</span>
                    <span :if={!tmpl.category} class="text-sm text-gray-500">&mdash;</span>
                  </td>
                  <td class="px-6 py-4 hidden md:table-cell">
                    <span class="text-sm text-gray-300">{length(tmpl.variables || [])}</span>
                  </td>
                  <td class="px-6 py-4 hidden lg:table-cell">
                    <span class="text-sm text-gray-400">v{tmpl.version}</span>
                  </td>
                  <td class="px-6 py-4">
                    <button
                      :if={AuthHooks.has_socket_permission?(assigns, "agents:update")}
                      phx-click="toggle_enabled"
                      phx-value-id={tmpl.id}
                      class="cursor-pointer"
                    >
                      <.enabled_badge enabled={tmpl.enabled} />
                    </button>
                    <.enabled_badge
                      :if={!AuthHooks.has_socket_permission?(assigns, "agents:update")}
                      enabled={tmpl.enabled}
                    />
                  </td>
                  <td class="px-6 py-4 text-right">
                    <div class="flex items-center justify-end gap-2">
                      <.link
                        :if={AuthHooks.has_socket_permission?(assigns, "agents:update")}
                        patch={~p"/admin/prompt-templates/#{tmpl.id}/edit"}
                        class="inline-flex items-center h-[36px] px-4 text-sm rounded bg-gray-700 hover:bg-gray-600 text-gray-100 transition-colors"
                      >
                        <.icon name="hero-pencil" class="size-3.5" />
                      </.link>
                      <button
                        :if={AuthHooks.has_socket_permission?(assigns, "agents:delete")}
                        phx-click="delete"
                        phx-value-id={tmpl.id}
                        data-confirm={"Delete template \"#{tmpl.name}\"? This cannot be undone."}
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
          id="prompt-templates-empty"
          class="bg-gray-800 border border-gray-700 rounded-lg p-12 text-center"
        >
          <.icon name="hero-document-text" class="size-12 mx-auto text-gray-600 mb-4" />
          <p class="text-gray-400 mb-4">No prompt templates configured</p>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "agents:create")}
            patch={~p"/admin/prompt-templates/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> Create First Template
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Badge components
  # -------------------------------------------------------------------

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
