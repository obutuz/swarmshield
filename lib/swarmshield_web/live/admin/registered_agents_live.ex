defmodule SwarmshieldWeb.Admin.RegisteredAgentsLive do
  @moduledoc """
  Admin CRUD for registered external AI agents.

  Manages agent registration, API key generation/regeneration,
  status toggle (active/suspended), risk level, and deletion
  (blocked if agent has events in last 24h).
  Permission: agents:view / agents:create / agents:update / agents:delete.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Gateway
  alias Swarmshield.Gateway.RegisteredAgent
  alias SwarmshieldWeb.Hooks.AuthHooks

  # -------------------------------------------------------------------
  # Mount
  # -------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    workspace_id = socket.assigns.current_workspace.id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "registered_agents:#{workspace_id}")
    end

    {:ok, assign(socket, :page_title, "Registered Agents")}
  end

  # -------------------------------------------------------------------
  # Handle params
  # -------------------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "agents:view") do
      apply_action(socket, socket.assigns.live_action, params)
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view registered agents.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  defp apply_action(socket, :index, _params) do
    workspace_id = socket.assigns.current_workspace.id
    {agents, total} = Gateway.list_registered_agents(workspace_id)

    existing_key = Map.get(socket.assigns, :newly_generated_key)

    {:noreply,
     socket
     |> assign(:page_title, "Registered Agents")
     |> assign(:total_count, total)
     |> assign(:newly_generated_key, existing_key)
     |> assign(:form, nil)
     |> assign(:agent, nil)
     |> stream(:agents, agents, reset: true)}
  end

  defp apply_action(socket, :new, _params) do
    changeset = Gateway.change_registered_agent(%RegisteredAgent{})

    {:noreply,
     socket
     |> assign(:page_title, "Register Agent")
     |> assign(:form, to_form(changeset))
     |> assign(:agent, nil)
     |> assign(:newly_generated_key, nil)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    workspace_id = socket.assigns.current_workspace.id
    agent = Gateway.get_registered_agent_for_workspace!(id, workspace_id)
    changeset = Gateway.change_registered_agent(agent)

    {:noreply,
     socket
     |> assign(:page_title, "Edit Agent")
     |> assign(:form, to_form(changeset))
     |> assign(:agent, agent)
     |> assign(:newly_generated_key, nil)}
  end

  # -------------------------------------------------------------------
  # Events
  # -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"registered_agent" => params}, socket) do
    agent = socket.assigns.agent || %RegisteredAgent{}

    changeset =
      agent
      |> Gateway.change_registered_agent(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"registered_agent" => params}, socket) do
    case socket.assigns.live_action do
      :new -> create_agent(socket, params)
      :edit -> update_agent(socket, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "agents:delete") do
      do_delete(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("toggle_status", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "agents:update") do
      do_toggle_status(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("regenerate_key", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "agents:update") do
      do_regenerate_key(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("dismiss_key", _params, socket) do
    {:noreply, assign(socket, :newly_generated_key, nil)}
  end

  # -------------------------------------------------------------------
  # PubSub
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:agent_created, _id}, socket), do: reload_agents(socket)
  def handle_info({:agent_updated, _id}, socket), do: reload_agents(socket)
  def handle_info({:agent_deleted, _id}, socket), do: reload_agents(socket)
  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private: mutations
  # -------------------------------------------------------------------

  defp create_agent(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "agents:create") do
      workspace_id = socket.assigns.current_workspace.id

      case Gateway.create_registered_agent(workspace_id, params) do
        {:ok, _agent, raw_key} ->
          broadcast(workspace_id, :agent_created)

          {:noreply,
           socket
           |> assign(:newly_generated_key, raw_key)
           |> put_flash(
             :info,
             "Agent registered. Copy the API key now — it won't be shown again."
           )
           |> push_patch(to: ~p"/admin/registered-agents")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp update_agent(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "agents:update") do
      agent = socket.assigns.agent

      case Gateway.update_registered_agent(agent, params) do
        {:ok, _updated} ->
          broadcast(socket.assigns.current_workspace.id, :agent_updated)

          {:noreply,
           socket
           |> put_flash(:info, "Agent updated.")
           |> push_patch(to: ~p"/admin/registered-agents")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp do_delete(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    agent = Gateway.get_registered_agent_for_workspace!(id, workspace_id)

    case Gateway.delete_registered_agent(agent) do
      {:ok, _deleted} ->
        broadcast(workspace_id, :agent_deleted)

        {:noreply,
         socket
         |> stream_delete(:agents, agent)
         |> assign(:total_count, socket.assigns.total_count - 1)
         |> put_flash(:info, "Agent deleted.")}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete agent.")}
    end
  end

  defp do_toggle_status(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    agent = Gateway.get_registered_agent_for_workspace!(id, workspace_id)

    new_status = if agent.status == :active, do: "suspended", else: "active"

    case Gateway.update_registered_agent(agent, %{status: new_status}) do
      {:ok, updated} ->
        broadcast(workspace_id, :agent_updated)

        {:noreply,
         socket
         |> stream_insert(:agents, updated)
         |> put_flash(:info, "Agent #{new_status}.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        message = format_changeset_errors(changeset)
        {:noreply, put_flash(socket, :error, "Could not update status: #{message}")}
    end
  end

  defp do_regenerate_key(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    agent = Gateway.get_registered_agent_for_workspace!(id, workspace_id)

    case Gateway.regenerate_api_key(agent) do
      {:ok, _updated, raw_key} ->
        broadcast(workspace_id, :agent_updated)

        {:noreply,
         socket
         |> assign(:newly_generated_key, raw_key)
         |> put_flash(:info, "API key regenerated. Copy it now — it won't be shown again.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not regenerate API key.")}
    end
  end

  # -------------------------------------------------------------------
  # Private: helpers
  # -------------------------------------------------------------------

  defp reload_agents(socket) do
    workspace_id = socket.assigns.current_workspace.id
    {agents, total} = Gateway.list_registered_agents(workspace_id)

    {:noreply,
     socket
     |> assign(:total_count, total)
     |> stream(:agents, agents, reset: true)}
  end

  defp broadcast(workspace_id, event) do
    Phoenix.PubSub.broadcast_from(
      Swarmshield.PubSub,
      self(),
      "registered_agents:#{workspace_id}",
      {event, workspace_id}
    )
  end

  # -------------------------------------------------------------------
  # View helpers
  # -------------------------------------------------------------------

  defp status_class(:active), do: "bg-success/10 text-success border-[0.5px] border-success/30"
  defp status_class(:suspended), do: "bg-error/10 text-error border-[0.5px] border-error/30"

  defp status_class(:revoked),
    do: "bg-base-content/10 text-base-content/50 border-[0.5px] border-base-300"

  defp status_class(_),
    do: "bg-base-content/10 text-base-content/70 border-[0.5px] border-base-content/30"

  defp risk_class(:low), do: "bg-success/10 text-success border-[0.5px] border-success/30"
  defp risk_class(:medium), do: "bg-yellow-400/10 text-warning border-[0.5px] border-warning/30"
  defp risk_class(:high), do: "bg-error/10 text-error border-[0.5px] border-error/30"
  defp risk_class(:critical), do: "bg-accent/10 text-accent border-[0.5px] border-accent/30"

  defp risk_class(_),
    do: "bg-base-content/10 text-base-content/70 border-[0.5px] border-base-content/30"

  defp format_changeset_errors(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)
  end

  defp format_last_seen(nil), do: "Never"

  defp format_last_seen(dt) do
    Calendar.strftime(dt, "%b %d, %Y %H:%M")
  end

  @agent_type_options [
    {"Autonomous", "autonomous"},
    {"Semi-Autonomous", "semi_autonomous"},
    {"Tool Agent", "tool_agent"},
    {"Chatbot", "chatbot"}
  ]

  @status_options [
    {"Active", "active"},
    {"Suspended", "suspended"}
  ]

  @risk_level_options [
    {"Low", "low"},
    {"Medium", "medium"},
    {"High", "high"},
    {"Critical", "critical"}
  ]

  defp agent_type_options, do: @agent_type_options
  defp status_options, do: @status_options
  defp risk_level_options, do: @risk_level_options

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
      active_nav={:admin_registered_agents}
    >
      <div class="space-y-6">
        <%= if @live_action in [:new, :edit] do %>
          <.agent_form form={@form} action={@live_action} agent={@agent} />
        <% else %>
          <.agent_list
            streams={@streams}
            total_count={@total_count}
            newly_generated_key={@newly_generated_key}
            has_create={AuthHooks.has_socket_permission?(assigns, "agents:create")}
            has_update={AuthHooks.has_socket_permission?(assigns, "agents:update")}
            has_delete={AuthHooks.has_socket_permission?(assigns, "agents:delete")}
          />
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Components
  # -------------------------------------------------------------------

  attr :streams, :any, required: true
  attr :total_count, :integer, required: true
  attr :newly_generated_key, :string, default: nil
  attr :has_create, :boolean, default: false
  attr :has_update, :boolean, default: false
  attr :has_delete, :boolean, default: false

  defp agent_list(assigns) do
    ~H"""
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-3xl font-bold text-base-content">
          <.icon name="hero-cpu-chip" class="size-8 inline-block mr-1 text-info" /> Registered Agents
        </h1>
        <p class="text-base-content/70 mt-1">{@total_count} agent(s) registered</p>
      </div>
      <.link
        :if={@has_create}
        patch={~p"/admin/registered-agents/new"}
        class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-primary hover:bg-primary/80 text-white text-sm font-medium transition-colors"
      >
        <.icon name="hero-plus" class="size-4" /> Register Agent
      </.link>
    </div>

    <%!-- Newly generated key banner --%>
    <div
      :if={@newly_generated_key}
      class="bg-success/10 border-[0.5px] border-success/30 rounded-lg p-4 space-y-2"
    >
      <div class="flex items-center gap-2">
        <.icon name="hero-key" class="size-5 text-success" />
        <p class="text-sm font-medium text-success">
          API key generated — copy it now!
        </p>
      </div>
      <div class="flex items-center gap-2">
        <code class="flex-1 text-sm font-mono text-base-content bg-base-200 rounded px-3 py-2 break-all">
          {@newly_generated_key}
        </code>
      </div>
      <p class="text-xs text-base-content/50">This key will not be shown again. Store it securely.</p>
      <button
        type="button"
        phx-click="dismiss_key"
        class="text-xs text-base-content/70 hover:text-base-content/80 transition-colors"
      >
        Dismiss
      </button>
    </div>

    <%!-- Agents table --%>
    <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg overflow-hidden">
      <div class="overflow-x-auto">
        <table class="w-full min-w-[700px]">
          <thead>
            <tr class="border-b-[0.5px] border-base-300 text-left text-sm text-base-content/70">
              <th class="px-6 py-3 font-medium">Name</th>
              <th class="px-6 py-3 font-medium">Type</th>
              <th class="px-6 py-3 font-medium">Status</th>
              <th class="px-6 py-3 font-medium">Risk</th>
              <th class="px-6 py-3 font-medium">API Key</th>
              <th class="px-6 py-3 font-medium">Last Seen</th>
              <th class="px-6 py-3 font-medium text-right">Actions</th>
            </tr>
          </thead>
          <tbody id="agents" phx-update="stream">
            <tr
              :for={{dom_id, agent} <- @streams.agents}
              id={dom_id}
              class="border-b-[0.5px] border-base-300 hover:bg-base-200/30 transition-colors"
            >
              <td class="px-6 py-4">
                <p class="text-sm font-medium text-base-content">{agent.name}</p>
                <p :if={agent.description} class="text-xs text-base-content/50 truncate max-w-xs">
                  {agent.description}
                </p>
              </td>
              <td class="px-6 py-4">
                <span class="text-sm text-base-content/80">{agent.agent_type}</span>
              </td>
              <td class="px-6 py-4">
                <span class={"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{status_class(agent.status)}"}>
                  {agent.status}
                </span>
              </td>
              <td class="px-6 py-4">
                <span class={"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{risk_class(agent.risk_level)}"}>
                  {agent.risk_level}
                </span>
              </td>
              <td class="px-6 py-4">
                <span class="text-xs font-mono text-base-content/70">
                  {agent.api_key_prefix || "—"}...
                </span>
              </td>
              <td class="px-6 py-4 text-sm text-base-content/70">
                {format_last_seen(agent.last_seen_at)}
              </td>
              <td class="px-6 py-4 text-right">
                <div class="flex items-center justify-end gap-2">
                  <button
                    :if={@has_update}
                    type="button"
                    phx-click="toggle_status"
                    phx-value-id={agent.id}
                    class={[
                      "px-3 py-1.5 rounded text-xs font-medium transition-colors",
                      if(agent.status == :active,
                        do: "border-[0.5px] border-warning/30 text-warning hover:bg-yellow-400/10",
                        else: "border-[0.5px] border-success/30 text-success hover:bg-success/10"
                      )
                    ]}
                  >
                    {if agent.status == :active, do: "Suspend", else: "Activate"}
                  </button>
                  <.link
                    :if={@has_update}
                    patch={~p"/admin/registered-agents/#{agent.id}/edit"}
                    class="px-3 py-1.5 rounded border-[0.5px] border-base-300 text-base-content/80 hover:bg-base-200 text-xs font-medium transition-colors"
                  >
                    Edit
                  </.link>
                  <button
                    :if={@has_update}
                    type="button"
                    phx-click="regenerate_key"
                    phx-value-id={agent.id}
                    data-confirm="Regenerate API key? The current key will be invalidated immediately."
                    class="px-3 py-1.5 rounded border-[0.5px] border-info/30 text-info hover:bg-info/10 text-xs font-medium transition-colors"
                  >
                    Regen Key
                  </button>
                  <button
                    :if={@has_delete}
                    type="button"
                    phx-click="delete"
                    phx-value-id={agent.id}
                    data-confirm="Delete this agent? This action cannot be undone."
                    class="px-3 py-1.5 rounded border-[0.5px] border-error/30 text-error hover:bg-error/10 text-xs font-medium transition-colors"
                  >
                    Delete
                  </button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Empty state --%>
      <div
        :if={@total_count == 0}
        class="flex flex-col items-center justify-center py-16 text-base-content/50"
      >
        <.icon name="hero-cpu-chip" class="size-12 mb-3 text-base-content/30" />
        <p class="text-sm">No registered agents</p>
        <.link
          :if={@has_create}
          patch={~p"/admin/registered-agents/new"}
          class="mt-3 text-sm text-info hover:text-blue-300"
        >
          Register your first agent
        </.link>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :action, :atom, required: true
  attr :agent, :any, default: nil

  defp agent_form(assigns) do
    ~H"""
    <div>
      <.link
        patch={~p"/admin/registered-agents"}
        class="inline-flex items-center gap-1 text-sm text-base-content/70 hover:text-base-content/80 mb-4"
      >
        <.icon name="hero-arrow-left" class="size-4" /> Back to agents
      </.link>
      <h1 class="text-3xl font-bold text-base-content">
        {if @action == :new, do: "Register Agent", else: "Edit Agent"}
      </h1>
    </div>

    <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-6">
      <.form
        for={@form}
        id="registered-agent-form"
        phx-change="validate"
        phx-submit="save"
        class="space-y-5"
      >
        <div class="grid grid-cols-1 md:grid-cols-2 gap-5">
          <div>
            <.input
              field={@form[:name]}
              type="text"
              label="Agent Name"
              phx-debounce="300"
              required
            />
          </div>
          <div>
            <.input
              field={@form[:agent_type]}
              type="select"
              label="Agent Type"
              options={agent_type_options()}
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

        <div :if={@action == :edit} class="grid grid-cols-1 md:grid-cols-2 gap-5">
          <div>
            <.input
              field={@form[:status]}
              type="select"
              label="Status"
              options={status_options()}
              phx-debounce="300"
            />
          </div>
          <div>
            <.input
              field={@form[:risk_level]}
              type="select"
              label="Risk Level"
              options={risk_level_options()}
              phx-debounce="300"
            />
          </div>
        </div>

        <div class="flex justify-end gap-3 pt-2">
          <.link
            patch={~p"/admin/registered-agents"}
            class="inline-flex items-center h-[44px] px-6 rounded-lg border-[0.5px] border-base-300 text-base-content/80 hover:bg-base-200 text-sm font-medium transition-colors"
          >
            Cancel
          </.link>
          <button
            type="submit"
            phx-disable-with="Saving..."
            class="inline-flex items-center h-[44px] px-6 rounded-lg bg-primary hover:bg-primary/80 text-white text-sm font-medium transition-colors"
          >
            {if @action == :new, do: "Register Agent", else: "Save Changes"}
          </button>
        </div>
      </.form>
    </div>
    """
  end
end
