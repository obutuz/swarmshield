defmodule SwarmshieldWeb.Admin.WorkflowShowLive do
  @moduledoc """
  Admin workflow detail with pipeline step editor.

  Displays workflow configuration, GhostProtocol config panel, and an
  ordered step pipeline with add/remove/reorder operations. All step
  mutations require workflows:update permission and are broadcast via
  PubSub for real-time multi-admin collaboration.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Agents
  alias Swarmshield.Deliberation.WorkflowStep
  alias Swarmshield.Workflows
  alias SwarmshieldWeb.Hooks.AuthHooks

  # -------------------------------------------------------------------
  # Lifecycle
  # -------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Workflow")}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "workflows:view") do
      {:noreply, load_workflow(socket, id)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to view workflows.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  defp load_workflow(socket, workflow_id) do
    workspace_id = socket.assigns.current_workspace.id
    workflow = Workflows.get_workflow_for_workspace!(workflow_id, workspace_id)
    steps = workflow.workflow_steps

    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        Swarmshield.PubSub,
        "workflow_steps:#{workflow.id}"
      )
    end

    agent_defs = Agents.list_enabled_agent_definitions_for_select(workspace_id)
    templates = Agents.list_enabled_prompt_templates_for_select(workspace_id)
    changeset = Workflows.change_workflow_step(%WorkflowStep{})

    socket
    |> assign(:page_title, workflow.name)
    |> assign(:workflow, workflow)
    |> assign(:step_count, length(steps))
    |> assign(:agent_def_options, agent_defs)
    |> assign(:template_options, templates)
    |> assign(:step_form, to_form(changeset))
    |> stream(:steps, steps, reset: true)
  end

  # -------------------------------------------------------------------
  # Events: Step form validate + submit
  # -------------------------------------------------------------------

  @impl true
  def handle_event("validate_step", %{"workflow_step" => params}, socket) do
    changeset =
      %WorkflowStep{}
      |> Workflows.change_workflow_step(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :step_form, to_form(changeset))}
  end

  def handle_event("add_step", %{"workflow_step" => params}, socket) do
    if AuthHooks.has_socket_permission?(socket, "workflows:update") do
      add_step(socket, params)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("delete_step", %{"id" => step_id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "workflows:update") do
      delete_step(socket, step_id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("move_up", %{"id" => step_id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "workflows:update") do
      move_step(socket, step_id, :up)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("move_down", %{"id" => step_id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "workflows:update") do
      move_step(socket, step_id, :down)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  # -------------------------------------------------------------------
  # PubSub handlers
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:step_created, step}, socket) do
    {:noreply,
     socket
     |> stream_insert(:steps, step)
     |> update(:step_count, &(&1 + 1))}
  end

  def handle_info({:step_deleted, step}, socket) do
    {:noreply,
     socket
     |> stream_delete(:steps, step)
     |> update(:step_count, &max(&1 - 1, 0))}
  end

  def handle_info({:steps_reordered, steps}, socket) do
    {:noreply, stream(socket, :steps, steps, reset: true)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private: add step
  # -------------------------------------------------------------------

  defp add_step(socket, params) do
    workspace_id = socket.assigns.current_workspace.id
    workflow = socket.assigns.workflow

    agent_def_id = params["agent_definition_id"]
    template_id = normalize_id(params["prompt_template_id"])

    case verify_step_associations(agent_def_id, template_id, workspace_id) do
      :ok ->
        create_and_stream_step(socket, workflow, params, template_id)

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp verify_step_associations(agent_def_id, template_id, workspace_id) do
    cond do
      agent_def_id not in ["", nil] &&
          !Agents.workspace_agent_definition?(agent_def_id, workspace_id) ->
        {:error, "Invalid agent definition."}

      template_id && !Agents.workspace_prompt_template?(template_id, workspace_id) ->
        {:error, "Invalid prompt template."}

      true ->
        :ok
    end
  end

  defp create_and_stream_step(socket, workflow, params, template_id) do
    next_pos = Workflows.next_step_position(workflow.id)

    attrs =
      params
      |> Map.put("workflow_id", workflow.id)
      |> Map.put("position", next_pos)
      |> Map.put("prompt_template_id", template_id)

    case Workflows.create_workflow_step(attrs) do
      {:ok, step} ->
        broadcast_step_change(workflow.id, {:step_created, step})
        changeset = Workflows.change_workflow_step(%WorkflowStep{})

        {:noreply,
         socket
         |> stream_insert(:steps, step)
         |> update(:step_count, &(&1 + 1))
         |> assign(:step_form, to_form(changeset))
         |> put_flash(:info, "Step added.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :step_form, to_form(changeset))}
    end
  end

  # -------------------------------------------------------------------
  # Private: delete step
  # -------------------------------------------------------------------

  defp delete_step(socket, step_id) do
    workflow = socket.assigns.workflow

    step = Workflows.get_workflow_step!(step_id)

    if step.workflow_id != workflow.id do
      {:noreply, put_flash(socket, :error, "Step not found.")}
    else
      case Workflows.delete_workflow_step(step) do
        {:ok, _deleted} ->
          broadcast_step_change(workflow.id, {:step_deleted, step})

          {:noreply,
           socket
           |> stream_delete(:steps, step)
           |> update(:step_count, &max(&1 - 1, 0))
           |> put_flash(:info, "Step removed.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not delete step.")}
      end
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Step not found.")}
  end

  # -------------------------------------------------------------------
  # Private: move step (reorder)
  # -------------------------------------------------------------------

  defp move_step(socket, step_id, direction) do
    workflow = socket.assigns.workflow
    steps = Workflows.list_workflow_steps(workflow.id)
    ordered_ids = Enum.map(steps, & &1.id)
    idx = Enum.find_index(ordered_ids, &(&1 == step_id))

    cond do
      is_nil(idx) ->
        {:noreply, put_flash(socket, :error, "Step not found.")}

      direction == :up && idx == 0 ->
        {:noreply, socket}

      direction == :down && idx == length(ordered_ids) - 1 ->
        {:noreply, socket}

      true ->
        swap_idx = if direction == :up, do: idx - 1, else: idx + 1
        new_order = swap_at(ordered_ids, idx, swap_idx)
        apply_reorder(socket, workflow.id, new_order)
    end
  end

  defp apply_reorder(socket, workflow_id, new_order) do
    case Workflows.reorder_workflow_steps(workflow_id, new_order) do
      {:ok, reordered_steps} ->
        broadcast_step_change(workflow_id, {:steps_reordered, reordered_steps})

        {:noreply, stream(socket, :steps, reordered_steps, reset: true)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not reorder steps.")}
    end
  end

  defp swap_at(list, idx1, idx2) do
    val1 = Enum.at(list, idx1)
    val2 = Enum.at(list, idx2)

    list
    |> List.replace_at(idx1, val2)
    |> List.replace_at(idx2, val1)
  end

  # -------------------------------------------------------------------
  # Private: helpers
  # -------------------------------------------------------------------

  defp normalize_id(""), do: nil
  defp normalize_id(nil), do: nil
  defp normalize_id(id) when is_binary(id), do: id

  defp broadcast_step_change(workflow_id, message) do
    Phoenix.PubSub.broadcast_from(
      Swarmshield.PubSub,
      self(),
      "workflow_steps:#{workflow_id}",
      message
    )
  end

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
      active_nav={:admin_workflows}
    >
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <div class="flex items-center gap-3 flex-wrap">
              <h1 class="text-2xl font-bold tracking-tight">{@workflow.name}</h1>
              <.enabled_badge enabled={@workflow.enabled} />
              <.ghost_badge config={@workflow.ghost_protocol_config} />
            </div>
            <p
              :if={@workflow.description}
              class="text-sm text-base-content/50 mt-1"
            >
              {@workflow.description}
            </p>
          </div>
          <div class="flex items-center gap-3">
            <.link
              :if={AuthHooks.has_socket_permission?(assigns, "workflows:update")}
              patch={~p"/admin/workflows/#{@workflow.id}/edit"}
              class="inline-flex items-center gap-2 h-[44px] px-4 rounded-lg border border-base-300/50 text-sm hover:bg-base-200/50 transition-colors"
            >
              <.icon name="hero-pencil" class="size-4" /> Edit
            </.link>
            <.link
              patch={~p"/admin/workflows"}
              class="inline-flex items-center gap-2 h-[44px] px-4 rounded-lg border border-base-300/50 text-sm hover:bg-base-200/50 transition-colors"
            >
              <.icon name="hero-arrow-left" class="size-4" /> Back
            </.link>
          </div>
        </div>

        <%!-- Workflow Details --%>
        <div class="rounded-xl border border-base-300/50 bg-base-100 p-6">
          <h2 class="text-lg font-semibold mb-4">Workflow Configuration</h2>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-6">
            <div>
              <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                Trigger
              </span>
              <div class="mt-1"><.trigger_badge trigger={@workflow.trigger_on} /></div>
            </div>
            <div>
              <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                Timeout
              </span>
              <div class="mt-1 text-sm font-medium tabular-nums">
                {@workflow.timeout_seconds}s
              </div>
            </div>
            <div>
              <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                Max Retries
              </span>
              <div class="mt-1 text-sm font-medium tabular-nums">
                {@workflow.max_retries}
              </div>
            </div>
            <div>
              <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
                Steps
              </span>
              <div class="mt-1 text-sm font-medium tabular-nums">{@step_count}</div>
            </div>
          </div>
        </div>

        <%!-- GhostProtocol Config Panel --%>
        <.ghost_protocol_panel config={@workflow.ghost_protocol_config} />

        <%!-- Pipeline Steps --%>
        <div>
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-lg font-semibold">
              <.icon name="hero-queue-list" class="size-5 inline-block mr-1 text-primary" />
              Pipeline Steps
            </h2>
            <span class="text-sm text-base-content/40">
              {@step_count} step{if @step_count != 1, do: "s"}
            </span>
          </div>

          <div :if={@step_count > 0} class="space-y-3" id="steps-stream" phx-update="stream">
            <.step_card
              :for={{dom_id, step} <- @streams.steps}
              id={dom_id}
              step={step}
              can_update={AuthHooks.has_socket_permission?(assigns, "workflows:update")}
            />
          </div>

          <div
            :if={@step_count == 0}
            id="steps-empty"
            class="rounded-xl border border-base-300/50 bg-base-100 p-12 text-center"
          >
            <.icon name="hero-queue-list" class="size-10 text-base-content/20 mx-auto mb-3" />
            <p class="text-sm text-base-content/40 mb-2">No pipeline steps configured</p>
            <p class="text-xs text-base-content/30">
              Add agent definitions below to build the deliberation pipeline
            </p>
          </div>
        </div>

        <%!-- Add Step Form --%>
        <div
          :if={AuthHooks.has_socket_permission?(assigns, "workflows:update")}
          class="rounded-xl border border-base-300/50 bg-base-100 p-6"
        >
          <h2 class="text-lg font-semibold mb-4">
            <.icon name="hero-plus-circle" class="size-5 inline-block mr-1 text-primary" />
            Add Pipeline Step
          </h2>
          <.form
            for={@step_form}
            id="step-form"
            phx-change="validate_step"
            phx-submit="add_step"
            class="space-y-4"
          >
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div>
                <.input
                  field={@step_form[:name]}
                  type="text"
                  label="Step Name"
                  phx-debounce="300"
                  required
                />
              </div>
              <div>
                <.input
                  field={@step_form[:agent_definition_id]}
                  type="select"
                  label="Agent Definition"
                  options={
                    [{"Select agent...", ""}] ++
                      Enum.map(@agent_def_options, fn {id, name} -> {name, id} end)
                  }
                  phx-debounce="300"
                  required
                />
              </div>
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
              <div>
                <.input
                  field={@step_form[:prompt_template_id]}
                  type="select"
                  label="Prompt Template"
                  options={
                    [{"None (use agent default)", ""}] ++
                      Enum.map(@template_options, fn {id, name} -> {name, id} end)
                  }
                  phx-debounce="300"
                />
              </div>
              <div>
                <.input
                  field={@step_form[:execution_mode]}
                  type="select"
                  label="Execution Mode"
                  options={execution_mode_options()}
                  phx-debounce="300"
                />
              </div>
              <div>
                <.input
                  field={@step_form[:timeout_seconds]}
                  type="number"
                  label="Timeout (seconds)"
                  phx-debounce="300"
                  min="10"
                  max="3600"
                />
              </div>
            </div>
            <div class="flex justify-end pt-2">
              <button
                type="submit"
                phx-disable-with="Adding..."
                class="inline-flex items-center h-[44px] px-6 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
              >
                <.icon name="hero-plus" class="size-4 mr-2" /> Add Step
              </button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Components
  # -------------------------------------------------------------------

  attr :step, :map, required: true
  attr :can_update, :boolean, required: true
  attr :id, :string, required: true

  defp step_card(assigns) do
    ~H"""
    <div
      id={@id}
      class="rounded-xl border border-base-300/50 bg-base-100 p-4 flex flex-col sm:flex-row sm:items-center gap-4"
    >
      <div class="flex-shrink-0 w-8 h-8 rounded-full bg-primary/10 text-primary text-sm font-bold flex items-center justify-center">
        {@step.position}
      </div>

      <div class="flex-1 min-w-0">
        <div class="font-medium text-sm">{@step.name}</div>
        <div class="text-xs text-base-content/40 flex items-center gap-2 mt-1 flex-wrap">
          <span class="inline-flex items-center gap-1">
            <.icon name="hero-cpu-chip" class="size-3" />
            {@step.agent_definition.name}
          </span>
          <span class="text-base-content/20">&middot;</span>
          <.execution_mode_badge mode={@step.execution_mode} />
          <span class="text-base-content/20">&middot;</span>
          <span class="tabular-nums">{@step.timeout_seconds}s</span>
          <span
            :if={@step.prompt_template}
            class="text-base-content/20"
          >
            &middot;
          </span>
          <span
            :if={@step.prompt_template}
            class="inline-flex items-center gap-1"
          >
            <.icon name="hero-document-text" class="size-3" />
            {@step.prompt_template.name}
          </span>
        </div>
      </div>

      <div :if={@can_update} class="flex items-center gap-1">
        <button
          phx-click="move_up"
          phx-value-id={@step.id}
          class="h-[36px] w-[36px] rounded border border-base-300/50 flex items-center justify-center hover:bg-base-200/50 transition-colors"
          title="Move up"
        >
          <.icon name="hero-chevron-up" class="size-4" />
        </button>
        <button
          phx-click="move_down"
          phx-value-id={@step.id}
          class="h-[36px] w-[36px] rounded border border-base-300/50 flex items-center justify-center hover:bg-base-200/50 transition-colors"
          title="Move down"
        >
          <.icon name="hero-chevron-down" class="size-4" />
        </button>
        <button
          phx-click="delete_step"
          phx-value-id={@step.id}
          data-confirm={"Remove step \"#{@step.name}\"?"}
          class="h-[36px] w-[36px] rounded border border-error/30 text-error flex items-center justify-center hover:bg-error/10 transition-colors"
          title="Remove step"
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  attr :config, :any, required: true

  defp ghost_protocol_panel(%{config: nil} = assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300/50 bg-base-100 p-4 flex items-center gap-3">
      <.icon name="hero-shield-check" class="size-5 text-base-content/30" />
      <span class="text-sm text-base-content/40">
        Standard (non-ephemeral) — deliberation data is retained
      </span>
    </div>
    """
  end

  defp ghost_protocol_panel(assigns) do
    ~H"""
    <div class="rounded-xl border border-secondary/20 bg-secondary/5 p-6">
      <div class="flex items-center gap-2 mb-4">
        <.icon name="hero-eye-slash" class="size-5 text-secondary" />
        <h2 class="text-lg font-semibold">GhostProtocol: {@config.name}</h2>
      </div>
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-4">
        <div>
          <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
            Wipe Strategy
          </span>
          <div class="mt-1 text-sm font-medium capitalize">{@config.wipe_strategy}</div>
        </div>
        <div>
          <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
            Crypto Shred
          </span>
          <div class="mt-1">
            <span
              :if={@config.crypto_shred}
              class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-warning/10 text-warning"
            >
              <.icon name="hero-lock-closed" class="size-3" /> Enabled
            </span>
            <span
              :if={!@config.crypto_shred}
              class="text-sm text-base-content/40"
            >
              Disabled
            </span>
          </div>
        </div>
        <div>
          <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
            Max Duration
          </span>
          <div class="mt-1 text-sm font-medium tabular-nums">
            {@config.max_session_duration_seconds}s
          </div>
        </div>
        <div>
          <span class="text-xs font-medium text-base-content/40 uppercase tracking-wider">
            Retain Verdict
          </span>
          <div class="mt-1 text-sm font-medium">
            {if @config.retain_verdict, do: "Yes", else: "No"}
          </div>
        </div>
      </div>
    </div>
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
    <span class="text-xs text-base-content/40">{@trigger}</span>
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

  attr :config, :any, required: true

  defp ghost_badge(%{config: nil} = assigns) do
    ~H"""
    """
  end

  defp ghost_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-medium bg-secondary/10 text-secondary">
      <.icon name="hero-eye-slash" class="size-3" /> Ephemeral
    </span>
    """
  end

  attr :mode, :atom, required: true

  defp execution_mode_badge(%{mode: :parallel} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium bg-info/10 text-info">
      Parallel
    </span>
    """
  end

  defp execution_mode_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[10px] font-medium bg-base-300/30 text-base-content/50">
      Sequential
    </span>
    """
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp execution_mode_options do
    [
      {"Sequential", :sequential},
      {"Parallel", :parallel}
    ]
  end
end
