defmodule SwarmshieldWeb.Admin.PoliciesLive do
  @moduledoc """
  Admin CRUD for consensus policies (voting strategies).

  Supports majority, supermajority, unanimous, and weighted voting
  configurations. Conditional form fields based on selected strategy.
  Streams for list display. PubSub real-time updates.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Deliberation.ConsensusPolicy
  alias Swarmshield.Workflows
  alias SwarmshieldWeb.Hooks.AuthHooks

  @strategy_options [
    {"Majority Vote", "majority"},
    {"Supermajority Vote", "supermajority"},
    {"Unanimous Vote", "unanimous"},
    {"Weighted Vote", "weighted"}
  ]

  # -------------------------------------------------------------------
  # Mount
  # -------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      workspace_id = socket.assigns.current_workspace.id

      Phoenix.PubSub.subscribe(
        Swarmshield.PubSub,
        "consensus_policies:#{workspace_id}"
      )
    end

    {:ok, assign(socket, :page_title, "Consensus Policies")}
  end

  # -------------------------------------------------------------------
  # Handle params (permission gate + data loading)
  # -------------------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "policies:view") do
      {:noreply, apply_action(socket, socket.assigns.live_action, params)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to manage consensus policies.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  defp apply_action(socket, :index, _params) do
    workspace_id = socket.assigns.current_workspace.id
    {policies, total_count} = Workflows.list_consensus_policies(workspace_id)

    socket
    |> assign(:page_title, "Consensus Policies")
    |> assign(:total_count, total_count)
    |> assign(:policy, nil)
    |> assign(:form, nil)
    |> assign(:weight_pairs, [])
    |> stream(:policies, policies, reset: true)
  end

  defp apply_action(socket, :new, _params) do
    changeset = Workflows.change_consensus_policy(%ConsensusPolicy{})

    socket
    |> assign(:page_title, "New Consensus Policy")
    |> assign(:policy, %ConsensusPolicy{})
    |> assign(:form, to_form(changeset))
    |> assign(:selected_strategy, "majority")
    |> assign(:weight_pairs, [%{key: "", value: ""}])
    |> assign(:require_unanimous_text, "")
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    workspace_id = socket.assigns.current_workspace.id
    policy = Workflows.get_consensus_policy_for_workspace!(id, workspace_id)
    changeset = Workflows.change_consensus_policy(policy)

    weight_pairs = weights_to_pairs(policy.weights)
    require_text = Enum.join(policy.require_unanimous_on || [], ", ")

    socket
    |> assign(:page_title, "Edit Consensus Policy")
    |> assign(:policy, policy)
    |> assign(:form, to_form(changeset))
    |> assign(:selected_strategy, to_string(policy.strategy))
    |> assign(:weight_pairs, weight_pairs)
    |> assign(:require_unanimous_text, require_text)
  end

  # -------------------------------------------------------------------
  # Events: Form validate + submit
  # -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"consensus_policy" => params}, socket) do
    selected_strategy = params["strategy"] || socket.assigns.selected_strategy

    changeset =
      (socket.assigns.policy || %ConsensusPolicy{})
      |> Workflows.change_consensus_policy(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset))
     |> assign(:selected_strategy, selected_strategy)}
  end

  def handle_event("save", %{"consensus_policy" => params}, socket) do
    params = enrich_params(params, socket)

    case socket.assigns.live_action do
      :new -> create_policy(socket, params)
      :edit -> update_policy(socket, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "policies:delete") do
      delete_verified_policy(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "policies:update") do
      toggle_verified_policy(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  # -------------------------------------------------------------------
  # Events: Weight pair editor
  # -------------------------------------------------------------------

  def handle_event("add_weight", _params, socket) do
    pairs = socket.assigns.weight_pairs ++ [%{key: "", value: ""}]
    {:noreply, assign(socket, :weight_pairs, pairs)}
  end

  def handle_event("remove_weight", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    pairs = List.delete_at(socket.assigns.weight_pairs, index)
    pairs = if pairs == [], do: [%{key: "", value: ""}], else: pairs
    {:noreply, assign(socket, :weight_pairs, pairs)}
  end

  def handle_event(
        "update_weight",
        %{"index" => idx_str, "field" => field, "value" => value},
        socket
      ) do
    index = String.to_integer(idx_str)

    pairs =
      List.update_at(socket.assigns.weight_pairs, index, fn pair ->
        Map.put(pair, String.to_existing_atom(field), value)
      end)

    {:noreply, assign(socket, :weight_pairs, pairs)}
  end

  # -------------------------------------------------------------------
  # Events: require_unanimous_on text
  # -------------------------------------------------------------------

  def handle_event("update_unanimous_text", %{"value" => value}, socket) do
    {:noreply, assign(socket, :require_unanimous_text, value)}
  end

  # -------------------------------------------------------------------
  # PubSub handlers
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:consensus_policy_created, policy}, socket) do
    {:noreply,
     socket
     |> stream_insert(:policies, policy, at: 0)
     |> update(:total_count, &(&1 + 1))}
  end

  def handle_info({:consensus_policy_updated, policy}, socket) do
    {:noreply, stream_insert(socket, :policies, policy)}
  end

  def handle_info({:consensus_policy_deleted, policy}, socket) do
    {:noreply,
     socket
     |> stream_delete(:policies, policy)
     |> update(:total_count, &max(&1 - 1, 0))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private: workspace-verified mutations
  # -------------------------------------------------------------------

  defp create_policy(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "policies:create") do
      workspace_id = socket.assigns.current_workspace.id

      case Workflows.create_consensus_policy(workspace_id, params) do
        {:ok, policy} ->
          Phoenix.PubSub.broadcast_from(
            Swarmshield.PubSub,
            self(),
            "consensus_policies:#{workspace_id}",
            {:consensus_policy_created, policy}
          )

          {:noreply,
           socket
           |> put_flash(:info, "Consensus policy created.")
           |> push_patch(to: ~p"/admin/consensus-policies")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp update_policy(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "policies:update") do
      workspace_id = socket.assigns.current_workspace.id
      policy = socket.assigns.policy

      case Workflows.update_consensus_policy(policy, params) do
        {:ok, updated} ->
          Phoenix.PubSub.broadcast_from(
            Swarmshield.PubSub,
            self(),
            "consensus_policies:#{workspace_id}",
            {:consensus_policy_updated, updated}
          )

          {:noreply,
           socket
           |> put_flash(:info, "Consensus policy updated.")
           |> push_patch(to: ~p"/admin/consensus-policies")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp delete_verified_policy(socket, id) do
    workspace_id = socket.assigns.current_workspace.id

    case Workflows.get_consensus_policy_for_workspace!(id, workspace_id) do
      policy ->
        case Workflows.delete_consensus_policy(policy) do
          {:ok, _deleted} ->
            Phoenix.PubSub.broadcast_from(
              Swarmshield.PubSub,
              self(),
              "consensus_policies:#{workspace_id}",
              {:consensus_policy_deleted, policy}
            )

            {:noreply,
             socket
             |> stream_delete(:policies, policy)
             |> update(:total_count, &max(&1 - 1, 0))
             |> put_flash(:info, "Consensus policy deleted.")}

          {:error, :referenced_by_sessions} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Cannot delete: policy is referenced by analysis sessions."
             )}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not delete consensus policy.")}
        end
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Policy not found.")}
  end

  defp toggle_verified_policy(socket, id) do
    workspace_id = socket.assigns.current_workspace.id

    case Workflows.get_consensus_policy_for_workspace!(id, workspace_id) do
      policy ->
        case Workflows.update_consensus_policy(policy, %{enabled: !policy.enabled}) do
          {:ok, updated} ->
            Phoenix.PubSub.broadcast_from(
              Swarmshield.PubSub,
              self(),
              "consensus_policies:#{workspace_id}",
              {:consensus_policy_updated, updated}
            )

            {:noreply, stream_insert(socket, :policies, updated)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not update policy.")}
        end
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Policy not found.")}
  end

  # -------------------------------------------------------------------
  # Private: param enrichment (weights map + require_unanimous_on)
  # -------------------------------------------------------------------

  defp enrich_params(params, socket) do
    strategy = params["strategy"] || socket.assigns.selected_strategy

    params
    |> maybe_build_weights(strategy, socket.assigns.weight_pairs)
    |> maybe_build_require_unanimous(socket.assigns.require_unanimous_text)
  end

  defp maybe_build_weights(params, "weighted", weight_pairs) do
    weights =
      weight_pairs
      |> Enum.reject(fn %{key: k} -> k == "" end)
      |> Map.new(fn %{key: k, value: v} ->
        {k, parse_weight(v)}
      end)

    Map.put(params, "weights", weights)
  end

  defp maybe_build_weights(params, _strategy, _pairs) do
    Map.put(params, "weights", %{})
  end

  defp maybe_build_require_unanimous(params, text) when is_binary(text) do
    items =
      text
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Map.put(params, "require_unanimous_on", items)
  end

  defp maybe_build_require_unanimous(params, _), do: params

  defp parse_weight(value) when is_binary(value) do
    case Float.parse(value) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  defp parse_weight(value) when is_number(value), do: value
  defp parse_weight(_), do: 0.0

  defp weights_to_pairs(nil), do: [%{key: "", value: ""}]
  defp weights_to_pairs(weights) when map_size(weights) == 0, do: [%{key: "", value: ""}]

  defp weights_to_pairs(weights) when is_map(weights) do
    Enum.map(weights, fn {k, v} -> %{key: k, value: to_string(v)} end)
  end

  # -------------------------------------------------------------------
  # Render: Create / Edit form
  # -------------------------------------------------------------------

  @impl true
  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    assigns = assign(assigns, :strategy_options, @strategy_options)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_policies}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-gray-100">
              {if @live_action == :new, do: "New Consensus Policy", else: "Edit Consensus Policy"}
            </h1>
            <p class="text-gray-400 mt-1">
              Configure voting strategy for deliberation verdicts
            </p>
          </div>
          <.link
            patch={~p"/admin/consensus-policies"}
            class="inline-flex items-center gap-2 h-[44px] px-4 rounded-lg border border-gray-600 text-sm text-gray-100 hover:bg-gray-800 transition-colors"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to Policies
          </.link>
        </div>

        <div class="bg-gray-800 border border-gray-700 rounded-lg p-6">
          <.form
            for={@form}
            id="policy-form"
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
                  field={@form[:strategy]}
                  type="select"
                  label="Strategy"
                  options={@strategy_options}
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

            <%!-- Threshold: shown for majority and supermajority --%>
            <div :if={@selected_strategy in ["majority", "supermajority"]}>
              <.input
                field={@form[:threshold]}
                type="number"
                label="Threshold (0.0 - 1.0)"
                phx-debounce="300"
                step="0.01"
                min="0"
                max="1"
              />
              <p class="text-xs text-gray-500 mt-1">
                {threshold_help(@selected_strategy)}
              </p>
            </div>

            <%!-- Weights: shown for weighted strategy --%>
            <div :if={@selected_strategy == "weighted"} class="space-y-3">
              <label class="block text-sm font-medium text-gray-300">
                Agent Weights
              </label>
              <p class="text-xs text-gray-500 mb-2">
                Assign voting weights to agent roles. Higher weights = more influence.
              </p>

              <div class="space-y-2">
                <div
                  :for={{pair, index} <- Enum.with_index(@weight_pairs)}
                  class="flex items-center gap-2"
                >
                  <input
                    type="text"
                    value={pair.key}
                    placeholder="Agent role"
                    phx-blur="update_weight"
                    phx-value-index={index}
                    phx-value-field="key"
                    phx-debounce="300"
                    class="flex-1 h-[44px] bg-gray-900 border border-gray-600 rounded-lg text-gray-100 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 px-3"
                  />
                  <input
                    type="number"
                    value={pair.value}
                    placeholder="Weight"
                    step="0.1"
                    min="0.1"
                    phx-blur="update_weight"
                    phx-value-index={index}
                    phx-value-field="value"
                    phx-debounce="300"
                    class="w-24 sm:w-32 h-[44px] bg-gray-900 border border-gray-600 rounded-lg text-gray-100 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 px-3"
                  />
                  <button
                    type="button"
                    phx-click="remove_weight"
                    phx-value-index={index}
                    class="h-[44px] px-3 rounded-lg border border-red-400/30 text-red-400 hover:bg-red-400/10 transition-colors"
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>
              </div>

              <button
                type="button"
                phx-click="add_weight"
                class="inline-flex items-center gap-1 h-[36px] px-4 text-sm rounded border border-gray-600 text-gray-300 hover:bg-gray-700 transition-colors"
              >
                <.icon name="hero-plus" class="size-3.5" /> Add Weight
              </button>
            </div>

            <%!-- Require unanimous on: shown for all strategies --%>
            <div>
              <label class="block text-sm font-medium text-gray-300 mb-1">
                Require Unanimous On
              </label>
              <input
                type="text"
                value={@require_unanimous_text}
                placeholder="e.g. critical_security, data_breach"
                phx-blur="update_unanimous_text"
                phx-debounce="300"
                class="w-full h-[44px] bg-gray-900 border border-gray-600 rounded-lg text-gray-100 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 px-3"
              />
              <p class="text-xs text-gray-500 mt-1">
                Comma-separated categories that always require unanimous vote regardless of strategy
              </p>
            </div>

            <div>
              <.input
                field={@form[:enabled]}
                type="checkbox"
                label="Enabled"
              />
            </div>

            <div class="flex justify-end gap-3 pt-4 border-t border-gray-700">
              <.link
                patch={~p"/admin/consensus-policies"}
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
                {if @live_action == :new, do: "Create Policy", else: "Save Changes"}
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
      active_nav={:admin_policies}
    >
      <div class="space-y-6">
        <%!-- Header --%>
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-gray-100">
              <.icon name="hero-scale" class="size-8 inline-block mr-1 text-blue-400" />
              Consensus Policies
            </h1>
            <p class="text-gray-400 mt-1">
              {@total_count} polic{if @total_count == 1, do: "y", else: "ies"} configured
            </p>
          </div>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "policies:create")}
            patch={~p"/admin/consensus-policies/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> New Policy
          </.link>
        </div>

        <%!-- Policy List --%>
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
                    Strategy
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider hidden md:table-cell">
                    Threshold
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="text-right px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody id="policies-stream" phx-update="stream">
                <tr
                  :for={{dom_id, policy} <- @streams.policies}
                  id={dom_id}
                  class="border-b border-gray-700 hover:bg-gray-800/50 transition-colors"
                >
                  <td class="px-6 py-4">
                    <div class="font-medium text-sm text-gray-100">{policy.name}</div>
                    <div
                      :if={policy.description}
                      class="text-xs text-gray-500 truncate max-w-[200px]"
                    >
                      {policy.description}
                    </div>
                  </td>
                  <td class="px-6 py-4 hidden sm:table-cell">
                    <.strategy_badge strategy={policy.strategy} />
                  </td>
                  <td class="px-6 py-4 hidden md:table-cell">
                    <.threshold_display strategy={policy.strategy} threshold={policy.threshold} />
                  </td>
                  <td class="px-6 py-4">
                    <button
                      :if={AuthHooks.has_socket_permission?(assigns, "policies:update")}
                      phx-click="toggle_enabled"
                      phx-value-id={policy.id}
                      class="cursor-pointer"
                    >
                      <.enabled_badge enabled={policy.enabled} />
                    </button>
                    <.enabled_badge
                      :if={!AuthHooks.has_socket_permission?(assigns, "policies:update")}
                      enabled={policy.enabled}
                    />
                  </td>
                  <td class="px-6 py-4 text-right">
                    <div class="flex items-center justify-end gap-2">
                      <.link
                        :if={AuthHooks.has_socket_permission?(assigns, "policies:update")}
                        patch={~p"/admin/consensus-policies/#{policy.id}/edit"}
                        class="inline-flex items-center h-[36px] px-4 text-sm rounded bg-gray-700 hover:bg-gray-600 text-gray-100 transition-colors"
                      >
                        <.icon name="hero-pencil" class="size-3.5" />
                      </.link>
                      <button
                        :if={AuthHooks.has_socket_permission?(assigns, "policies:delete")}
                        phx-click="delete"
                        phx-value-id={policy.id}
                        data-confirm={"Delete policy \"#{policy.name}\"? This cannot be undone."}
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

        <%!-- Empty state --%>
        <div
          :if={@total_count == 0}
          id="policies-empty"
          class="bg-gray-800 border border-gray-700 rounded-lg p-12 text-center"
        >
          <.icon name="hero-scale" class="size-12 mx-auto text-gray-600 mb-4" />
          <p class="text-gray-400 mb-4">No consensus policies configured</p>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "policies:create")}
            patch={~p"/admin/consensus-policies/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> Create First Policy
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

  defp strategy_badge(%{strategy: :majority} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-400/20 text-blue-400">
      Majority
    </span>
    """
  end

  defp strategy_badge(%{strategy: :supermajority} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-purple-400/20 text-purple-400">
      Supermajority
    </span>
    """
  end

  defp strategy_badge(%{strategy: :unanimous} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-400/20 text-yellow-400">
      Unanimous
    </span>
    """
  end

  defp strategy_badge(%{strategy: :weighted} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-400/20 text-green-400">
      Weighted
    </span>
    """
  end

  defp strategy_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-400/20 text-gray-400">
      {@strategy}
    </span>
    """
  end

  attr :strategy, :atom, required: true
  attr :threshold, :float, required: true

  defp threshold_display(%{strategy: :unanimous} = assigns) do
    ~H"""
    <span class="text-sm text-gray-500">N/A (always 100%)</span>
    """
  end

  defp threshold_display(%{strategy: :weighted} = assigns) do
    ~H"""
    <span class="text-sm text-gray-500">Weighted</span>
    """
  end

  defp threshold_display(%{threshold: nil} = assigns) do
    ~H"""
    <span class="text-sm text-gray-500">—</span>
    """
  end

  defp threshold_display(assigns) do
    ~H"""
    <span class="text-sm tabular-nums text-gray-100">
      {Float.round(@threshold * 100, 1)}%
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

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp threshold_help("majority"),
    do: "Fraction of votes needed to pass (e.g. 0.5 = simple majority)"

  defp threshold_help("supermajority"),
    do: "Fraction of votes needed (typically 0.67 for two-thirds)"

  defp threshold_help(_), do: ""
end
