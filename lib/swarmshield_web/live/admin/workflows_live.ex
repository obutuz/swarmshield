defmodule SwarmshieldWeb.Admin.WorkflowsLive do
  @moduledoc """
  Admin CRUD for deliberation workflows.

  Lists workflows with streams, supports create/edit/delete with
  permission checks on every state-changing event. PubSub broadcasts
  on enable/disable toggle. Ghost protocol config selector for
  ephemeral workflow linking.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Deliberation.Workflow
  alias Swarmshield.GhostProtocol
  alias Swarmshield.Workflows
  alias SwarmshieldWeb.Hooks.AuthHooks

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      workspace_id = socket.assigns.current_workspace.id

      Phoenix.PubSub.subscribe(
        Swarmshield.PubSub,
        "workflows:#{workspace_id}"
      )
    end

    {:ok, assign(socket, :page_title, "Workflows")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "workflows:view") do
      {:noreply, apply_action(socket, socket.assigns.live_action, params)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to manage workflows.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  # -------------------------------------------------------------------
  # Actions
  # -------------------------------------------------------------------

  defp apply_action(socket, :index, _params) do
    workspace_id = socket.assigns.current_workspace.id

    {workflows, total_count} = Workflows.list_workflows(workspace_id)
    gp_configs = GhostProtocol.list_enabled_configs_for_select(workspace_id)

    socket
    |> assign(:page_title, "Workflows")
    |> assign(:total_count, total_count)
    |> assign(:gp_config_options, gp_configs)
    |> assign(:workflow, nil)
    |> assign(:form, nil)
    |> stream(:workflows, workflows, reset: true)
  end

  defp apply_action(socket, :new, _params) do
    workspace_id = socket.assigns.current_workspace.id
    gp_configs = GhostProtocol.list_enabled_configs_for_select(workspace_id)
    changeset = Workflows.change_workflow(%Workflow{})

    socket
    |> assign(:page_title, "New Workflow")
    |> assign(:gp_config_options, gp_configs)
    |> assign(:workflow, %Workflow{})
    |> assign(:form, to_form(changeset))
    |> assign(:ghost_protocol_config_id, nil)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    workspace_id = socket.assigns.current_workspace.id

    workflow = Workflows.get_workflow!(id)

    if workflow.workspace_id != workspace_id do
      raise Ecto.NoResultsError, queryable: Workflow
    end

    gp_configs = GhostProtocol.list_enabled_configs_for_select(workspace_id)
    changeset = Workflows.change_workflow(workflow)

    socket
    |> assign(:page_title, "Edit Workflow")
    |> assign(:gp_config_options, gp_configs)
    |> assign(:workflow, workflow)
    |> assign(:form, to_form(changeset))
    |> assign(:ghost_protocol_config_id, workflow.ghost_protocol_config_id)
  end

  # -------------------------------------------------------------------
  # Events: Form validate + submit
  # -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"workflow" => params}, socket) do
    changeset =
      (socket.assigns.workflow || %Workflow{})
      |> Workflows.change_workflow(params)
      |> Map.put(:action, :validate)

    ghost_protocol_config_id = normalize_config_id(params["ghost_protocol_config_id"])

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:ghost_protocol_config_id, ghost_protocol_config_id)}
  end

  def handle_event("save", %{"workflow" => params}, socket) do
    case socket.assigns.live_action do
      :new -> create_workflow(socket, params)
      :edit -> update_workflow(socket, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "workflows:delete") do
      delete_verified_workflow(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "workflows:update") do
      toggle_verified_workflow(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  # -------------------------------------------------------------------
  # PubSub handlers
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:workflow_created, workflow}, socket) do
    {:noreply,
     socket
     |> stream_insert(:workflows, workflow, at: 0)
     |> update(:total_count, &(&1 + 1))}
  end

  def handle_info({:workflow_updated, workflow}, socket) do
    {:noreply, stream_insert(socket, :workflows, workflow)}
  end

  def handle_info({:workflow_deleted, workflow}, socket) do
    {:noreply,
     socket
     |> stream_delete(:workflows, workflow)
     |> update(:total_count, &max(&1 - 1, 0))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private: workspace-verified mutations
  # -------------------------------------------------------------------

  defp delete_verified_workflow(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    workflow = Workflows.get_workflow!(id)

    if workflow.workspace_id != workspace_id do
      {:noreply, put_flash(socket, :error, "Workflow not found.")}
    else
      case Workflows.delete_workflow(workflow) do
        {:ok, _deleted} ->
          {:noreply,
           socket
           |> stream_delete(:workflows, workflow)
           |> update(:total_count, &max(&1 - 1, 0))
           |> put_flash(:info, "Workflow deleted.")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not delete workflow.")}
      end
    end
  end

  defp toggle_verified_workflow(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    workflow = Workflows.get_workflow!(id)

    if workflow.workspace_id != workspace_id do
      {:noreply, put_flash(socket, :error, "Workflow not found.")}
    else
      case Workflows.update_workflow(workflow, %{enabled: !workflow.enabled}) do
        {:ok, updated} ->
          updated = Workflows.preload_workflow_assocs(updated)

          Phoenix.PubSub.broadcast_from(
            Swarmshield.PubSub,
            self(),
            "workflows:#{workspace_id}",
            {:workflow_updated, updated}
          )

          {:noreply, stream_insert(socket, :workflows, updated)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not update workflow.")}
      end
    end
  end

  # -------------------------------------------------------------------
  # Private: create / update
  # -------------------------------------------------------------------

  defp create_workflow(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "workflows:create") do
      workspace_id = socket.assigns.current_workspace.id
      ghost_protocol_config_id = normalize_config_id(params["ghost_protocol_config_id"])

      attrs =
        params
        |> Map.put("ghost_protocol_config_id", ghost_protocol_config_id)

      case Workflows.create_workflow(workspace_id, attrs) do
        {:ok, workflow} ->
          workflow =
            Workflows.preload_workflow_assocs(workflow)

          Phoenix.PubSub.broadcast_from(
            Swarmshield.PubSub,
            self(),
            "workflows:#{workspace_id}",
            {:workflow_created, workflow}
          )

          {:noreply,
           socket
           |> put_flash(:info, "Workflow created.")
           |> push_patch(to: ~p"/admin/workflows")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp update_workflow(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "workflows:update") do
      workspace_id = socket.assigns.current_workspace.id
      workflow = socket.assigns.workflow
      ghost_protocol_config_id = normalize_config_id(params["ghost_protocol_config_id"])

      attrs =
        params
        |> Map.put("ghost_protocol_config_id", ghost_protocol_config_id)

      case Workflows.update_workflow(workflow, attrs) do
        {:ok, updated} ->
          updated =
            Workflows.preload_workflow_assocs(updated)

          Phoenix.PubSub.broadcast_from(
            Swarmshield.PubSub,
            self(),
            "workflows:#{workspace_id}",
            {:workflow_updated, updated}
          )

          {:noreply,
           socket
           |> put_flash(:info, "Workflow updated.")
           |> push_patch(to: ~p"/admin/workflows")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp normalize_config_id(""), do: nil
  defp normalize_config_id(nil), do: nil
  defp normalize_config_id(id) when is_binary(id), do: id

  # -------------------------------------------------------------------
  # Render
  # -------------------------------------------------------------------

  @impl true
  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_workflows}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">
              {if @live_action == :new, do: "New Workflow", else: "Edit Workflow"}
            </h1>
            <p class="text-sm text-base-content/50 mt-1">
              Configure the deliberation pipeline
            </p>
          </div>
          <.link
            patch={~p"/admin/workflows"}
            class="inline-flex items-center gap-2 h-[44px] px-4 rounded-lg border border-base-300/50 text-sm hover:bg-base-200/50 transition-colors"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to Workflows
          </.link>
        </div>

        <div class="rounded-xl border border-base-300/50 bg-base-100 p-6">
          <.form
            for={@form}
            id="workflow-form"
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
                />
              </div>

              <div>
                <.input
                  field={@form[:trigger_on]}
                  type="select"
                  label="Trigger On"
                  options={trigger_options()}
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
                rows="3"
              />
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-3 gap-5">
              <div>
                <.input
                  field={@form[:timeout_seconds]}
                  type="number"
                  label="Timeout (seconds)"
                  phx-debounce="300"
                  min="30"
                  max="3600"
                />
              </div>

              <div>
                <.input
                  field={@form[:max_retries]}
                  type="number"
                  label="Max Retries"
                  phx-debounce="300"
                  min="0"
                  max="10"
                />
              </div>

              <div>
                <label class="block text-sm font-medium mb-1">GhostProtocol Config</label>
                <select
                  name="workflow[ghost_protocol_config_id]"
                  phx-debounce="300"
                  class="select select-bordered w-full h-[44px]"
                >
                  <option value="">None (Standard)</option>
                  <%= for {id, name} <- @gp_config_options do %>
                    <option value={id} selected={@ghost_protocol_config_id == id}>
                      {name}
                    </option>
                  <% end %>
                </select>
              </div>
            </div>

            <div>
              <.input
                field={@form[:enabled]}
                type="checkbox"
                label="Enabled"
              />
            </div>

            <div class="flex justify-end gap-3 pt-4 border-t border-base-300/30">
              <.link
                patch={~p"/admin/workflows"}
                class="inline-flex items-center h-[44px] px-6 rounded-lg border border-base-300/50 text-sm hover:bg-base-200/50 transition-colors"
              >
                Cancel
              </.link>
              <button
                type="submit"
                phx-disable-with="Saving..."
                class="inline-flex items-center h-[44px] px-6 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
              >
                <.icon name="hero-check" class="size-4 mr-2" />
                {if @live_action == :new, do: "Create Workflow", else: "Save Changes"}
              </button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_workflows}
    >
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">
              <.icon name="hero-arrow-path" class="size-7 inline-block mr-1 text-primary" /> Workflows
            </h1>
            <p class="text-sm text-base-content/50 mt-1">
              {@total_count} workflow{if @total_count != 1, do: "s"} configured
            </p>
          </div>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "workflows:create")}
            patch={~p"/admin/workflows/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> New Workflow
          </.link>
        </div>

        <%!-- Workflow List --%>
        <div :if={@total_count > 0} class="rounded-xl border border-base-300/50 bg-base-100">
          <div class="overflow-x-auto">
            <table class="table w-full">
              <thead>
                <tr class="border-b border-base-300/30">
                  <th class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                    Name
                  </th>
                  <th class="text-xs font-medium text-base-content/40 uppercase tracking-wider hidden sm:table-cell">
                    Trigger
                  </th>
                  <th class="text-xs font-medium text-base-content/40 uppercase tracking-wider hidden md:table-cell">
                    Steps
                  </th>
                  <th class="text-xs font-medium text-base-content/40 uppercase tracking-wider hidden md:table-cell">
                    Protocol
                  </th>
                  <th class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="text-xs font-medium text-base-content/40 uppercase tracking-wider text-right">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody id="workflows-stream" phx-update="stream">
                <tr
                  :for={{dom_id, workflow} <- @streams.workflows}
                  id={dom_id}
                  class="border-b border-base-300/20 hover:bg-base-200/30 transition-colors"
                >
                  <td class="py-3">
                    <.link
                      navigate={~p"/admin/workflows/#{workflow.id}"}
                      class="font-medium text-sm hover:text-primary transition-colors"
                    >
                      {workflow.name}
                    </.link>
                    <div
                      :if={workflow.description}
                      class="text-xs text-base-content/40 truncate max-w-[200px]"
                    >
                      {workflow.description}
                    </div>
                  </td>
                  <td class="py-3 hidden sm:table-cell">
                    <.trigger_badge trigger={workflow.trigger_on} />
                  </td>
                  <td class="py-3 hidden md:table-cell">
                    <span class="text-sm tabular-nums">
                      {length(workflow.workflow_steps)}
                    </span>
                  </td>
                  <td class="py-3 hidden md:table-cell">
                    <.protocol_badge config={workflow.ghost_protocol_config} />
                  </td>
                  <td class="py-3">
                    <button
                      :if={AuthHooks.has_socket_permission?(assigns, "workflows:update")}
                      phx-click="toggle_enabled"
                      phx-value-id={workflow.id}
                      class="cursor-pointer"
                    >
                      <.enabled_badge enabled={workflow.enabled} />
                    </button>
                    <.enabled_badge
                      :if={!AuthHooks.has_socket_permission?(assigns, "workflows:update")}
                      enabled={workflow.enabled}
                    />
                  </td>
                  <td class="py-3 text-right">
                    <div class="flex items-center justify-end gap-2">
                      <.link
                        :if={AuthHooks.has_socket_permission?(assigns, "workflows:update")}
                        patch={~p"/admin/workflows/#{workflow.id}/edit"}
                        class="inline-flex items-center h-[36px] px-3 rounded border border-base-300/50 text-xs hover:bg-base-200/50 transition-colors"
                      >
                        <.icon name="hero-pencil" class="size-3.5" />
                      </.link>
                      <button
                        :if={AuthHooks.has_socket_permission?(assigns, "workflows:delete")}
                        phx-click="delete"
                        phx-value-id={workflow.id}
                        data-confirm={"Delete workflow \"#{workflow.name}\"? This cannot be undone."}
                        class="inline-flex items-center h-[36px] px-3 rounded border border-error/30 text-error text-xs hover:bg-error/10 transition-colors"
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

        <%!-- Empty state --%>
        <div
          :if={@total_count == 0}
          id="workflows-empty"
          class="rounded-xl border border-base-300/50 bg-base-100 p-12 text-center"
        >
          <.icon name="hero-arrow-path" class="size-10 text-base-content/20 mx-auto mb-3" />
          <p class="text-sm text-base-content/40 mb-4">No workflows configured</p>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "workflows:create")}
            patch={~p"/admin/workflows/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> Create First Workflow
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Badge components
  # -------------------------------------------------------------------

  attr :trigger, :atom, required: true

  defp trigger_badge(%{trigger: :flagged} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-warning/10 text-warning">
      <.icon name="hero-flag" class="size-3" /> Flagged
    </span>
    """
  end

  defp trigger_badge(%{trigger: :blocked} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-error/10 text-error">
      <.icon name="hero-no-symbol" class="size-3" /> Blocked
    </span>
    """
  end

  defp trigger_badge(%{trigger: :manual} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-info/10 text-info">
      <.icon name="hero-hand-raised" class="size-3" /> Manual
    </span>
    """
  end

  defp trigger_badge(%{trigger: :all} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-primary/10 text-primary">
      <.icon name="hero-signal" class="size-3" /> All
    </span>
    """
  end

  defp trigger_badge(assigns) do
    ~H"""
    <span class="badge badge-ghost badge-xs">{@trigger}</span>
    """
  end

  attr :config, :any, required: true

  defp protocol_badge(%{config: nil} = assigns) do
    ~H"""
    <span class="text-xs text-base-content/30">Standard</span>
    """
  end

  defp protocol_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-secondary/10 text-secondary">
      <.icon name="hero-eye-slash" class="size-3" /> {@config.name}
    </span>
    """
  end

  attr :enabled, :boolean, required: true

  defp enabled_badge(%{enabled: true} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-success/10 text-success">
      <.icon name="hero-check-circle" class="size-3" /> Enabled
    </span>
    """
  end

  defp enabled_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-base-300/30 text-base-content/40">
      <.icon name="hero-x-circle" class="size-3" /> Disabled
    </span>
    """
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp trigger_options do
    [
      {"Flagged Events", :flagged},
      {"Blocked Events", :blocked},
      {"Manual Trigger", :manual},
      {"All Events", :all}
    ]
  end
end
