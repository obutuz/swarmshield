defmodule SwarmshieldWeb.Admin.PolicyRulesLive do
  @moduledoc """
  Admin CRUD for policy rules (allow/flag/block).

  Dynamic config fields based on rule_type. PubSub broadcasts on
  changes trigger ETS cache refresh. Streams for list display.
  Permission checks on mount and every state-changing event.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Policies
  alias Swarmshield.Policies.PolicyRule
  alias SwarmshieldWeb.Hooks.AuthHooks

  @rule_type_options [
    {"Rate Limit", "rate_limit"},
    {"Pattern Match", "pattern_match"},
    {"Blocklist", "blocklist"},
    {"Allowlist", "allowlist"},
    {"Payload Size", "payload_size"},
    {"Custom", "custom"}
  ]

  @action_options [
    {"Allow", "allow"},
    {"Flag", "flag"},
    {"Block", "block"}
  ]

  # -------------------------------------------------------------------
  # Mount
  # -------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      workspace_id = socket.assigns.current_workspace.id
      Policies.subscribe_policy_rules(workspace_id)
    end

    {:ok, assign(socket, :page_title, "Policy Rules")}
  end

  # -------------------------------------------------------------------
  # Handle params
  # -------------------------------------------------------------------

  @impl true
  def handle_params(params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "policies:view") do
      {:noreply, apply_action(socket, socket.assigns.live_action, params)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to manage policy rules.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  defp apply_action(socket, :index, _params) do
    workspace_id = socket.assigns.current_workspace.id
    {rules, total_count} = Policies.list_policy_rules(workspace_id)

    socket
    |> assign(:page_title, "Policy Rules")
    |> assign(:total_count, total_count)
    |> assign(:rule, nil)
    |> assign(:form, nil)
    |> stream(:rules, rules, reset: true)
  end

  defp apply_action(socket, :new, _params) do
    workspace_id = socket.assigns.current_workspace.id
    rule = %PolicyRule{rule_type: :rate_limit, action: :flag, config: %{}}
    changeset = Policies.change_policy_rule(rule)
    detection_rules = Policies.list_detection_rules_for_select(workspace_id)

    socket
    |> assign(:page_title, "New Policy Rule")
    |> assign(:rule, rule)
    |> assign(:form, to_form(changeset))
    |> assign(:selected_rule_type, "rate_limit")
    |> assign(:detection_rule_options, detection_rules)
    |> assign_default_config_fields("rate_limit")
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    workspace_id = socket.assigns.current_workspace.id
    rule = Policies.get_policy_rule_for_workspace!(id, workspace_id)
    changeset = Policies.change_policy_rule(rule)
    detection_rules = Policies.list_detection_rules_for_select(workspace_id)

    socket
    |> assign(:page_title, "Edit Policy Rule")
    |> assign(:rule, rule)
    |> assign(:form, to_form(changeset))
    |> assign(:selected_rule_type, to_string(rule.rule_type))
    |> assign(:detection_rule_options, detection_rules)
    |> assign_config_fields_from_rule(rule)
  end

  # -------------------------------------------------------------------
  # Events: Form validate + submit
  # -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"policy_rule" => params}, socket) do
    new_type = params["rule_type"] || socket.assigns.selected_rule_type
    old_type = socket.assigns.selected_rule_type

    changeset =
      (socket.assigns.rule || %PolicyRule{})
      |> Policies.change_policy_rule(params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_rule_type, new_type)

    socket =
      if new_type != old_type do
        assign_default_config_fields(socket, new_type)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("save", %{"policy_rule" => params}, socket) do
    params = build_config_params(params, socket)

    case socket.assigns.live_action do
      :new -> create_rule(socket, params)
      :edit -> update_rule(socket, params)
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "policies:delete") do
      delete_verified_rule(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "policies:update") do
      toggle_verified_rule(socket, id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  # Config field events
  def handle_event("update_config", %{"field" => field, "value" => value}, socket) do
    {:noreply, assign(socket, String.to_existing_atom(field), value)}
  end

  def handle_event("toggle_detection_rule", %{"id" => id}, socket) do
    current = socket.assigns.selected_detection_rule_ids

    updated =
      if id in current,
        do: List.delete(current, id),
        else: current ++ [id]

    {:noreply, assign(socket, :selected_detection_rule_ids, updated)}
  end

  # -------------------------------------------------------------------
  # PubSub handlers
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:policy_rules_changed, action, rule_id}, socket) do
    workspace_id = socket.assigns.current_workspace.id

    case action do
      :created ->
        rule = Policies.get_policy_rule!(rule_id)

        if rule.workspace_id == workspace_id do
          {:noreply,
           socket
           |> stream_insert(:rules, rule, at: 0)
           |> update(:total_count, &(&1 + 1))}
        else
          {:noreply, socket}
        end

      :updated ->
        rule = Policies.get_policy_rule!(rule_id)

        if rule.workspace_id == workspace_id do
          {:noreply, stream_insert(socket, :rules, rule)}
        else
          {:noreply, socket}
        end

      :deleted ->
        {:noreply, socket}
    end
  rescue
    Ecto.NoResultsError -> {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private: mutations
  # -------------------------------------------------------------------

  defp create_rule(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "policies:create") do
      workspace_id = socket.assigns.current_workspace.id

      case Policies.create_policy_rule(workspace_id, params) do
        {:ok, _rule} ->
          {:noreply,
           socket
           |> put_flash(:info, "Policy rule created.")
           |> push_patch(to: ~p"/admin/policy-rules")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp update_rule(socket, params) do
    if AuthHooks.has_socket_permission?(socket, "policies:update") do
      rule = socket.assigns.rule

      case Policies.update_policy_rule(rule, params) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "Policy rule updated.")
           |> push_patch(to: ~p"/admin/policy-rules")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp delete_verified_rule(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    rule = Policies.get_policy_rule_for_workspace!(id, workspace_id)

    case Policies.delete_policy_rule(rule) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> stream_delete(:rules, rule)
         |> update(:total_count, &max(&1 - 1, 0))
         |> put_flash(:info, "Policy rule deleted.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          Enum.map_join(changeset.errors, ", ", fn {_field, {message, _}} -> message end)

        {:noreply, put_flash(socket, :error, "Cannot delete: #{msg}")}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Rule not found.")}
  end

  defp toggle_verified_rule(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    rule = Policies.get_policy_rule_for_workspace!(id, workspace_id)

    case Policies.update_policy_rule(rule, %{enabled: !rule.enabled}) do
      {:ok, updated} ->
        {:noreply, stream_insert(socket, :rules, updated)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not update rule.")}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Rule not found.")}
  end

  # -------------------------------------------------------------------
  # Private: config field helpers
  # -------------------------------------------------------------------

  defp assign_default_config_fields(socket, "rate_limit") do
    socket
    |> assign(:cfg_max_events, "")
    |> assign(:cfg_window_seconds, "")
    |> assign(:selected_detection_rule_ids, [])
    |> assign(:cfg_values_text, "")
    |> assign(:cfg_max_content_bytes, "")
    |> assign(:cfg_max_payload_bytes, "")
  end

  defp assign_default_config_fields(socket, "pattern_match") do
    socket
    |> assign(:cfg_max_events, "")
    |> assign(:cfg_window_seconds, "")
    |> assign(:selected_detection_rule_ids, [])
    |> assign(:cfg_values_text, "")
    |> assign(:cfg_max_content_bytes, "")
    |> assign(:cfg_max_payload_bytes, "")
  end

  defp assign_default_config_fields(socket, type) when type in ["blocklist", "allowlist"] do
    socket
    |> assign(:cfg_max_events, "")
    |> assign(:cfg_window_seconds, "")
    |> assign(:selected_detection_rule_ids, [])
    |> assign(:cfg_values_text, "")
    |> assign(:cfg_max_content_bytes, "")
    |> assign(:cfg_max_payload_bytes, "")
  end

  defp assign_default_config_fields(socket, "payload_size") do
    socket
    |> assign(:cfg_max_events, "")
    |> assign(:cfg_window_seconds, "")
    |> assign(:selected_detection_rule_ids, [])
    |> assign(:cfg_values_text, "")
    |> assign(:cfg_max_content_bytes, "")
    |> assign(:cfg_max_payload_bytes, "")
  end

  defp assign_default_config_fields(socket, _type) do
    socket
    |> assign(:cfg_max_events, "")
    |> assign(:cfg_window_seconds, "")
    |> assign(:selected_detection_rule_ids, [])
    |> assign(:cfg_values_text, "")
    |> assign(:cfg_max_content_bytes, "")
    |> assign(:cfg_max_payload_bytes, "")
  end

  defp assign_config_fields_from_rule(socket, %PolicyRule{config: config, rule_type: :rate_limit}) do
    socket
    |> assign(:cfg_max_events, to_string(config["max_events"] || ""))
    |> assign(:cfg_window_seconds, to_string(config["window_seconds"] || ""))
    |> assign(:selected_detection_rule_ids, [])
    |> assign(:cfg_values_text, "")
    |> assign(:cfg_max_content_bytes, "")
    |> assign(:cfg_max_payload_bytes, "")
  end

  defp assign_config_fields_from_rule(socket, %PolicyRule{
         config: config,
         rule_type: :pattern_match
       }) do
    ids = config["detection_rule_ids"] || []

    socket
    |> assign(:cfg_max_events, "")
    |> assign(:cfg_window_seconds, "")
    |> assign(:selected_detection_rule_ids, ids)
    |> assign(:cfg_values_text, "")
    |> assign(:cfg_max_content_bytes, "")
    |> assign(:cfg_max_payload_bytes, "")
  end

  defp assign_config_fields_from_rule(socket, %PolicyRule{config: config, rule_type: type})
       when type in [:blocklist, :allowlist] do
    values = config["values"] || []

    socket
    |> assign(:cfg_max_events, "")
    |> assign(:cfg_window_seconds, "")
    |> assign(:selected_detection_rule_ids, [])
    |> assign(:cfg_values_text, Enum.join(values, "\n"))
    |> assign(:cfg_max_content_bytes, "")
    |> assign(:cfg_max_payload_bytes, "")
  end

  defp assign_config_fields_from_rule(socket, %PolicyRule{
         config: config,
         rule_type: :payload_size
       }) do
    socket
    |> assign(:cfg_max_events, "")
    |> assign(:cfg_window_seconds, "")
    |> assign(:selected_detection_rule_ids, [])
    |> assign(:cfg_values_text, "")
    |> assign(:cfg_max_content_bytes, to_string(config["max_content_bytes"] || ""))
    |> assign(:cfg_max_payload_bytes, to_string(config["max_payload_bytes"] || ""))
  end

  defp assign_config_fields_from_rule(socket, _rule) do
    assign_default_config_fields(socket, "custom")
  end

  defp build_config_params(params, socket) do
    config =
      case socket.assigns.selected_rule_type do
        "rate_limit" ->
          %{
            "max_events" => parse_int(socket.assigns.cfg_max_events),
            "window_seconds" => parse_int(socket.assigns.cfg_window_seconds)
          }

        "pattern_match" ->
          %{"detection_rule_ids" => socket.assigns.selected_detection_rule_ids}

        type when type in ["blocklist", "allowlist"] ->
          values =
            socket.assigns.cfg_values_text
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          %{"values" => values}

        "payload_size" ->
          %{
            "max_content_bytes" => parse_int(socket.assigns.cfg_max_content_bytes),
            "max_payload_bytes" => parse_int(socket.assigns.cfg_max_payload_bytes)
          }

        _custom ->
          %{}
      end

    Map.put(params, "config", config)
  end

  defp parse_int(""), do: nil

  defp parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {num, _} -> num
      :error -> nil
    end
  end

  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(_), do: nil

  # -------------------------------------------------------------------
  # Render: Create / Edit form
  # -------------------------------------------------------------------

  @impl true
  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    assigns =
      assigns
      |> assign(:rule_type_options, @rule_type_options)
      |> assign(:action_options, @action_options)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_policy_rules}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-gray-100">
              {if @live_action == :new, do: "New Policy Rule", else: "Edit Policy Rule"}
            </h1>
            <p class="text-gray-400 mt-1">
              Configure event evaluation rules
            </p>
          </div>
          <.link
            patch={~p"/admin/policy-rules"}
            class="inline-flex items-center gap-2 h-[44px] px-4 rounded-lg border border-gray-600 text-sm text-gray-100 hover:bg-gray-800 transition-colors"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to Rules
          </.link>
        </div>

        <div class="bg-gray-800 border border-gray-700 rounded-lg p-6">
          <.form
            for={@form}
            id="rule-form"
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
                  field={@form[:rule_type]}
                  type="select"
                  label="Rule Type"
                  options={@rule_type_options}
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
                rows="2"
              />
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-3 gap-5">
              <div>
                <.input
                  field={@form[:action]}
                  type="select"
                  label="Action"
                  options={@action_options}
                  phx-debounce="300"
                  required
                />
              </div>
              <div>
                <.input
                  field={@form[:priority]}
                  type="number"
                  label="Priority"
                  phx-debounce="300"
                  step="1"
                  min="0"
                />
              </div>
              <div class="flex items-end pb-1">
                <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
              </div>
            </div>

            <%!-- Dynamic config fields based on rule_type --%>
            <div class="border-t border-gray-700 pt-5">
              <h3 class="text-sm font-semibold text-gray-300 mb-3">
                Configuration — {rule_type_label(@selected_rule_type)}
              </h3>

              <.config_fields
                rule_type={@selected_rule_type}
                cfg_max_events={@cfg_max_events}
                cfg_window_seconds={@cfg_window_seconds}
                detection_rule_options={@detection_rule_options}
                selected_detection_rule_ids={@selected_detection_rule_ids}
                cfg_values_text={@cfg_values_text}
                cfg_max_content_bytes={@cfg_max_content_bytes}
                cfg_max_payload_bytes={@cfg_max_payload_bytes}
              />
            </div>

            <div class="flex justify-end gap-3 pt-4 border-t border-gray-700">
              <.link
                patch={~p"/admin/policy-rules"}
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
                {if @live_action == :new, do: "Create Rule", else: "Save Changes"}
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
      active_nav={:admin_policy_rules}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-gray-100">
              <.icon name="hero-shield-check" class="size-8 inline-block mr-1 text-blue-400" />
              Policy Rules
            </h1>
            <p class="text-gray-400 mt-1">
              {@total_count} rule{if @total_count != 1, do: "s"} configured
            </p>
          </div>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "policies:create")}
            patch={~p"/admin/policy-rules/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> New Rule
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
                    Type
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider hidden sm:table-cell">
                    Action
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider hidden md:table-cell">
                    Priority
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="text-right px-6 py-3 text-xs font-medium text-gray-400 uppercase tracking-wider">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody id="rules-stream" phx-update="stream">
                <tr
                  :for={{dom_id, rule} <- @streams.rules}
                  id={dom_id}
                  class={[
                    "border-b border-gray-700 transition-colors",
                    if(rule.enabled,
                      do: "hover:bg-gray-800/50",
                      else: "opacity-50 hover:bg-gray-800/30"
                    )
                  ]}
                >
                  <td class="px-6 py-4">
                    <div class="font-medium text-sm text-gray-100">{rule.name}</div>
                    <div
                      :if={rule.description}
                      class="text-xs text-gray-500 truncate max-w-[200px]"
                    >
                      {rule.description}
                    </div>
                  </td>
                  <td class="px-6 py-4 hidden sm:table-cell">
                    <.rule_type_badge type={rule.rule_type} />
                  </td>
                  <td class="px-6 py-4 hidden sm:table-cell">
                    <.action_badge action={rule.action} />
                  </td>
                  <td class="px-6 py-4 hidden md:table-cell">
                    <span class="text-sm tabular-nums text-gray-100">{rule.priority}</span>
                  </td>
                  <td class="px-6 py-4">
                    <button
                      :if={AuthHooks.has_socket_permission?(assigns, "policies:update")}
                      phx-click="toggle_enabled"
                      phx-value-id={rule.id}
                      class="cursor-pointer"
                    >
                      <.enabled_badge enabled={rule.enabled} />
                    </button>
                    <.enabled_badge
                      :if={!AuthHooks.has_socket_permission?(assigns, "policies:update")}
                      enabled={rule.enabled}
                    />
                  </td>
                  <td class="px-6 py-4 text-right">
                    <div class="flex items-center justify-end gap-2">
                      <.link
                        :if={AuthHooks.has_socket_permission?(assigns, "policies:update")}
                        patch={~p"/admin/policy-rules/#{rule.id}/edit"}
                        class="inline-flex items-center h-[36px] px-4 text-sm rounded bg-gray-700 hover:bg-gray-600 text-gray-100 transition-colors"
                      >
                        <.icon name="hero-pencil" class="size-3.5" />
                      </.link>
                      <button
                        :if={AuthHooks.has_socket_permission?(assigns, "policies:delete")}
                        phx-click="delete"
                        phx-value-id={rule.id}
                        data-confirm={"Delete rule \"#{rule.name}\"? This cannot be undone."}
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
          id="rules-empty"
          class="bg-gray-800 border border-gray-700 rounded-lg p-12 text-center"
        >
          <.icon name="hero-shield-check" class="size-12 mx-auto text-gray-600 mb-4" />
          <p class="text-gray-400 mb-4">No policy rules configured</p>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "policies:create")}
            patch={~p"/admin/policy-rules/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-blue-600 hover:bg-blue-700 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> Create First Rule
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Dynamic config fields component
  # -------------------------------------------------------------------

  attr :rule_type, :string, required: true
  attr :cfg_max_events, :string, default: ""
  attr :cfg_window_seconds, :string, default: ""
  attr :detection_rule_options, :list, default: []
  attr :selected_detection_rule_ids, :list, default: []
  attr :cfg_values_text, :string, default: ""
  attr :cfg_max_content_bytes, :string, default: ""
  attr :cfg_max_payload_bytes, :string, default: ""

  defp config_fields(%{rule_type: "rate_limit"} = assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <div>
        <label class="block text-sm font-medium text-gray-300 mb-1">Max Events</label>
        <input
          type="number"
          value={@cfg_max_events}
          phx-blur="update_config"
          phx-value-field="cfg_max_events"
          phx-debounce="300"
          min="1"
          step="1"
          placeholder="e.g. 100"
          class="w-full h-[44px] bg-gray-900 border border-gray-600 rounded-lg text-gray-100 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 px-3"
        />
        <p class="text-xs text-gray-500 mt-1">Maximum events allowed in the time window</p>
      </div>
      <div>
        <label class="block text-sm font-medium text-gray-300 mb-1">Window (seconds)</label>
        <input
          type="number"
          value={@cfg_window_seconds}
          phx-blur="update_config"
          phx-value-field="cfg_window_seconds"
          phx-debounce="300"
          min="1"
          step="1"
          placeholder="e.g. 60"
          class="w-full h-[44px] bg-gray-900 border border-gray-600 rounded-lg text-gray-100 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 px-3"
        />
        <p class="text-xs text-gray-500 mt-1">Sliding window duration in seconds</p>
      </div>
    </div>
    """
  end

  defp config_fields(%{rule_type: "pattern_match"} = assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-xs text-gray-500">Select detection rules to match against:</p>
      <div
        :if={@detection_rule_options == []}
        class="text-sm text-gray-500 italic"
      >
        No enabled detection rules available. Create detection rules first.
      </div>
      <div class="space-y-2">
        <label
          :for={{id, name} <- @detection_rule_options}
          class="flex items-center gap-3 p-3 rounded-lg border border-gray-600 hover:bg-gray-700/50 transition-colors cursor-pointer"
        >
          <input
            type="checkbox"
            checked={id in @selected_detection_rule_ids}
            phx-click="toggle_detection_rule"
            phx-value-id={id}
            class="checkbox checkbox-sm checkbox-primary"
          />
          <span class="text-sm text-gray-100">{name}</span>
        </label>
      </div>
    </div>
    """
  end

  defp config_fields(%{rule_type: type} = assigns) when type in ["blocklist", "allowlist"] do
    ~H"""
    <div>
      <label class="block text-sm font-medium text-gray-300 mb-1">
        Values (one per line)
      </label>
      <textarea
        phx-blur="update_config"
        phx-value-field="cfg_values_text"
        phx-debounce="300"
        rows="6"
        placeholder={"Enter #{@rule_type} values, one per line"}
        class="w-full bg-gray-900 border border-gray-600 rounded-lg text-gray-100 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 px-3 py-2"
      >{@cfg_values_text}</textarea>
      <p class="text-xs text-gray-500 mt-1">
        {if @rule_type == "blocklist",
          do: "Blocked values - matching events will be actioned",
          else: "Allowed values - matching events will pass through"}
      </p>
    </div>
    """
  end

  defp config_fields(%{rule_type: "payload_size"} = assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
      <div>
        <label class="block text-sm font-medium text-gray-300 mb-1">Max Content (bytes)</label>
        <input
          type="number"
          value={@cfg_max_content_bytes}
          phx-blur="update_config"
          phx-value-field="cfg_max_content_bytes"
          phx-debounce="300"
          min="1"
          step="1"
          placeholder="e.g. 10240"
          class="w-full h-[44px] bg-gray-900 border border-gray-600 rounded-lg text-gray-100 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 px-3"
        />
        <p class="text-xs text-gray-500 mt-1">Maximum content size in bytes</p>
      </div>
      <div>
        <label class="block text-sm font-medium text-gray-300 mb-1">Max Payload (bytes)</label>
        <input
          type="number"
          value={@cfg_max_payload_bytes}
          phx-blur="update_config"
          phx-value-field="cfg_max_payload_bytes"
          phx-debounce="300"
          min="1"
          step="1"
          placeholder="e.g. 51200"
          class="w-full h-[44px] bg-gray-900 border border-gray-600 rounded-lg text-gray-100 focus:border-blue-500 focus:ring-1 focus:ring-blue-500 px-3"
        />
        <p class="text-xs text-gray-500 mt-1">Maximum total payload size in bytes</p>
      </div>
    </div>
    """
  end

  defp config_fields(assigns) do
    ~H"""
    <p class="text-sm text-gray-500 italic">
      No additional configuration required for custom rule type.
    </p>
    """
  end

  # -------------------------------------------------------------------
  # Badge components
  # -------------------------------------------------------------------

  attr :type, :atom, required: true

  defp rule_type_badge(%{type: :rate_limit} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-400/20 text-blue-400">
      Rate Limit
    </span>
    """
  end

  defp rule_type_badge(%{type: :pattern_match} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-purple-400/20 text-purple-400">
      Pattern Match
    </span>
    """
  end

  defp rule_type_badge(%{type: :blocklist} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-400/20 text-red-400">
      Blocklist
    </span>
    """
  end

  defp rule_type_badge(%{type: :allowlist} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-400/20 text-green-400">
      Allowlist
    </span>
    """
  end

  defp rule_type_badge(%{type: :payload_size} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-400/20 text-yellow-400">
      Payload Size
    </span>
    """
  end

  defp rule_type_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-400/20 text-gray-400">
      {@type}
    </span>
    """
  end

  attr :action, :atom, required: true

  defp action_badge(%{action: :allow} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-400/20 text-green-400">
      <.icon name="hero-check-circle" class="size-3" /> Allow
    </span>
    """
  end

  defp action_badge(%{action: :flag} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-yellow-400/20 text-yellow-400">
      <.icon name="hero-flag" class="size-3" /> Flag
    </span>
    """
  end

  defp action_badge(%{action: :block} = assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-400/20 text-red-400">
      <.icon name="hero-no-symbol" class="size-3" /> Block
    </span>
    """
  end

  defp action_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-400/20 text-gray-400">
      {@action}
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

  defp rule_type_label("rate_limit"), do: "Rate Limit"
  defp rule_type_label("pattern_match"), do: "Pattern Match"
  defp rule_type_label("blocklist"), do: "Blocklist"
  defp rule_type_label("allowlist"), do: "Allowlist"
  defp rule_type_label("payload_size"), do: "Payload Size"
  defp rule_type_label(_), do: "Custom"
end
