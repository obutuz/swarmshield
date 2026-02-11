defmodule SwarmshieldWeb.Admin.DetectionRulesLive do
  @moduledoc """
  Admin CRUD for detection rules (regex patterns and keyword lists).

  Regex validation with compile check and ReDoS prevention.
  Conditional fields based on detection_type (regex/keyword/semantic).
  PubSub broadcasts on changes trigger ETS cache refresh.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Policies
  alias Swarmshield.Policies.DetectionRule
  alias SwarmshieldWeb.Hooks.AuthHooks

  @detection_type_options [
    {"Regex", "regex"},
    {"Keyword", "keyword"},
    {"Semantic", "semantic"}
  ]

  @severity_options [
    {"Low", "low"},
    {"Medium", "medium"},
    {"High", "high"},
    {"Critical", "critical"}
  ]

  @category_options [
    {"PII", "pii"},
    {"Credentials", "credentials"},
    {"Injection", "injection"},
    {"Profanity", "profanity"},
    {"Prompt Injection", "prompt_injection"},
    {"Data Exfiltration", "data_exfiltration"},
    {"Custom", "custom"}
  ]

  # -------------------------------------------------------------------
  # Mount
  # -------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      workspace_id = socket.assigns.current_workspace.id
      Policies.subscribe_detection_rules(workspace_id)
    end

    {:ok, assign(socket, :page_title, "Detection Rules")}
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
       |> put_flash(:error, "You are not authorized to manage detection rules.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  defp apply_action(socket, :index, _params) do
    workspace_id = socket.assigns.current_workspace.id
    {rules, total_count} = Policies.list_detection_rules(workspace_id)

    socket
    |> assign(:page_title, "Detection Rules")
    |> assign(:total_count, total_count)
    |> assign(:rule, nil)
    |> assign(:form, nil)
    |> stream(:rules, rules, reset: true)
  end

  defp apply_action(socket, :new, _params) do
    rule = %DetectionRule{detection_type: :regex}
    changeset = Policies.change_detection_rule(rule)

    socket
    |> assign(:page_title, "New Detection Rule")
    |> assign(:rule, rule)
    |> assign(:form, to_form(changeset))
    |> assign(:selected_type, "regex")
    |> assign(:keywords_text, "")
    |> assign(:regex_error, nil)
    |> assign(:regex_preview_input, "")
    |> assign(:regex_preview_result, nil)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    workspace_id = socket.assigns.current_workspace.id
    rule = Policies.get_detection_rule_for_workspace!(id, workspace_id)
    changeset = Policies.change_detection_rule(rule)

    keywords_text = Enum.join(rule.keywords || [], ", ")

    socket
    |> assign(:page_title, "Edit Detection Rule")
    |> assign(:rule, rule)
    |> assign(:form, to_form(changeset))
    |> assign(:selected_type, to_string(rule.detection_type))
    |> assign(:keywords_text, keywords_text)
    |> assign(:regex_error, nil)
    |> assign(:regex_preview_input, "")
    |> assign(:regex_preview_result, nil)
  end

  # -------------------------------------------------------------------
  # Events: Form validate + submit
  # -------------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"detection_rule" => params}, socket) do
    new_type = params["detection_type"] || socket.assigns.selected_type
    old_type = socket.assigns.selected_type

    changeset =
      (socket.assigns.rule || %DetectionRule{})
      |> Policies.change_detection_rule(params)
      |> Map.put(:action, :validate)

    regex_error = validate_regex_live(new_type, params["pattern"])

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:selected_type, new_type)
      |> assign(:regex_error, regex_error)

    socket =
      if new_type != old_type do
        socket
        |> assign(:keywords_text, "")
        |> assign(:regex_preview_input, "")
        |> assign(:regex_preview_result, nil)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("save", %{"detection_rule" => params}, socket) do
    params = enrich_params(params, socket)

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
  def handle_event("update_keywords", %{"value" => value}, socket) do
    {:noreply, assign(socket, :keywords_text, value)}
  end

  def handle_event("regex_preview", %{"input" => input}, socket) do
    pattern = get_current_pattern(socket)
    result = run_regex_preview(pattern, input)

    {:noreply,
     socket
     |> assign(:regex_preview_input, input)
     |> assign(:regex_preview_result, result)}
  end

  # -------------------------------------------------------------------
  # PubSub handlers
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:detection_rules_changed, action, rule_id}, socket) do
    workspace_id = socket.assigns.current_workspace.id

    case action do
      :created ->
        rule = Policies.get_detection_rule!(rule_id)

        if rule.workspace_id == workspace_id do
          {:noreply,
           socket
           |> stream_insert(:rules, rule, at: 0)
           |> update(:total_count, &(&1 + 1))}
        else
          {:noreply, socket}
        end

      :updated ->
        rule = Policies.get_detection_rule!(rule_id)

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

      case Policies.create_detection_rule(workspace_id, params) do
        {:ok, _rule} ->
          {:noreply,
           socket
           |> put_flash(:info, "Detection rule created.")
           |> push_patch(to: ~p"/admin/detection-rules")}

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

      case Policies.update_detection_rule(rule, params) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "Detection rule updated.")
           |> push_patch(to: ~p"/admin/detection-rules")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  defp delete_verified_rule(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    rule = Policies.get_detection_rule_for_workspace!(id, workspace_id)

    case Policies.delete_detection_rule(rule) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> stream_delete(:rules, rule)
         |> update(:total_count, &max(&1 - 1, 0))
         |> put_flash(:info, "Detection rule deleted.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not delete detection rule.")}
    end
  rescue
    Ecto.NoResultsError ->
      {:noreply, put_flash(socket, :error, "Rule not found.")}
  end

  defp toggle_verified_rule(socket, id) do
    workspace_id = socket.assigns.current_workspace.id
    rule = Policies.get_detection_rule_for_workspace!(id, workspace_id)

    case Policies.update_detection_rule(rule, %{enabled: !rule.enabled}) do
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
  # Private: param enrichment
  # -------------------------------------------------------------------

  defp enrich_params(params, socket) do
    case socket.assigns.selected_type do
      "keyword" ->
        keywords =
          socket.assigns.keywords_text
          |> String.split(~r/[,\n]/)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        Map.put(params, "keywords", keywords)

      _other ->
        params
    end
  end

  # -------------------------------------------------------------------
  # Private: regex validation + preview
  # -------------------------------------------------------------------

  defp validate_regex_live("regex", pattern) when is_binary(pattern) and pattern != "" do
    case Regex.compile(pattern) do
      {:ok, _} -> nil
      {:error, {reason, _}} -> "Invalid regex: #{reason}"
    end
  end

  defp validate_regex_live(_, _), do: nil

  defp get_current_pattern(socket) do
    case socket.assigns.form do
      %{source: %{changes: %{pattern: p}}} -> p
      _ -> socket.assigns.rule && socket.assigns.rule.pattern
    end
  end

  defp run_regex_preview(nil, _input), do: nil
  defp run_regex_preview("", _input), do: nil

  defp run_regex_preview(pattern, input) when is_binary(pattern) and is_binary(input) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        matches = Regex.scan(regex, input) |> List.flatten()

        if matches == [] do
          {:no_match, "No matches found"}
        else
          {:match, "#{length(matches)} match(es): #{Enum.join(matches, ", ")}"}
        end

      {:error, _} ->
        {:error, "Invalid regex pattern"}
    end
  end

  defp run_regex_preview(_, _), do: nil

  # -------------------------------------------------------------------
  # Render: Create / Edit form
  # -------------------------------------------------------------------

  @impl true
  def render(%{live_action: action} = assigns) when action in [:new, :edit] do
    assigns =
      assigns
      |> assign(:detection_type_options, @detection_type_options)
      |> assign(:severity_options, @severity_options)
      |> assign(:category_options, @category_options)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_detection_rules}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-base-content">
              {if @live_action == :new, do: "New Detection Rule", else: "Edit Detection Rule"}
            </h1>
            <p class="text-base-content/70 mt-1">Configure pattern matching for event analysis</p>
          </div>
          <.link
            patch={~p"/admin/detection-rules"}
            class="inline-flex items-center gap-2 h-[44px] px-4 rounded-lg border-[0.5px] border-base-300 text-sm text-base-content hover:bg-base-200 transition-colors"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to Rules
          </.link>
        </div>

        <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-6">
          <.form
            for={@form}
            id="detection-rule-form"
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
                  field={@form[:detection_type]}
                  type="select"
                  label="Detection Type"
                  options={@detection_type_options}
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
                  field={@form[:category]}
                  type="select"
                  label="Category"
                  options={@category_options}
                  phx-debounce="300"
                />
              </div>
              <div>
                <.input
                  field={@form[:severity]}
                  type="select"
                  label="Severity"
                  options={@severity_options}
                  phx-debounce="300"
                />
              </div>
              <div class="flex items-end pb-1">
                <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
              </div>
            </div>

            <%!-- Regex pattern field --%>
            <div
              :if={@selected_type == "regex"}
              class="border-t-[0.5px] border-base-300 pt-5 space-y-4"
            >
              <h3 class="text-sm font-semibold text-base-content/80">Regex Pattern</h3>
              <div>
                <.input
                  field={@form[:pattern]}
                  type="textarea"
                  label="Pattern"
                  phx-debounce="300"
                  rows="3"
                  placeholder="e.g. \\b(password|secret|api_key)\\b"
                />
                <div :if={@regex_error} class="mt-1 text-sm text-error">
                  {@regex_error}
                </div>
              </div>
              <%!-- Regex preview --%>
              <div class="bg-base-200 border-[0.5px] border-base-300 rounded-lg p-4 space-y-3">
                <label class="block text-sm font-medium text-base-content/70">
                  Test Pattern (preview)
                </label>
                <input
                  type="text"
                  value={@regex_preview_input}
                  phx-blur="regex_preview"
                  phx-value-input={@regex_preview_input}
                  phx-debounce="300"
                  placeholder="Enter sample text to test pattern..."
                  class="w-full h-[44px] bg-base-100 border-[0.5px] border-base-300 rounded-lg text-base-content focus:border-primary focus:ring-1 focus:ring-primary px-3"
                />
                <div :if={@regex_preview_result}>
                  <.preview_result result={@regex_preview_result} />
                </div>
              </div>
            </div>

            <%!-- Keyword list field --%>
            <div
              :if={@selected_type == "keyword"}
              class="border-t-[0.5px] border-base-300 pt-5 space-y-3"
            >
              <h3 class="text-sm font-semibold text-base-content/80">Keywords</h3>
              <div>
                <label class="block text-sm font-medium text-base-content/80 mb-1">
                  Keywords (comma or newline separated)
                </label>
                <textarea
                  phx-blur="update_keywords"
                  phx-debounce="300"
                  rows="5"
                  placeholder="password, secret, api_key&#10;bearer_token&#10;private_key"
                  class="w-full bg-base-200 border-[0.5px] border-base-300 rounded-lg text-base-content focus:border-primary focus:ring-1 focus:ring-primary px-3 py-2"
                >{@keywords_text}</textarea>
                <p class="text-xs text-base-content/50 mt-1">
                  Enter keywords separated by commas or newlines
                </p>
              </div>
            </div>

            <%!-- Semantic type info --%>
            <div :if={@selected_type == "semantic"} class="border-t-[0.5px] border-base-300 pt-5">
              <div class="bg-base-200/50 border-[0.5px] border-base-300 rounded-lg p-4">
                <p class="text-sm text-base-content/70">
                  Semantic detection uses AI-powered analysis. No additional pattern configuration needed.
                </p>
              </div>
            </div>

            <div class="flex justify-end gap-3 pt-4 border-t-[0.5px] border-base-300">
              <.link
                patch={~p"/admin/detection-rules"}
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
      active_nav={:admin_detection_rules}
    >
      <div class="space-y-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div>
            <h1 class="text-3xl font-bold text-base-content">
              <.icon name="hero-magnifying-glass" class="size-8 inline-block mr-1 text-info" />
              Detection Rules
            </h1>
            <p class="text-base-content/70 mt-1">
              {@total_count} rule{if @total_count != 1, do: "s"} configured
            </p>
          </div>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "policies:create")}
            patch={~p"/admin/detection-rules/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-primary hover:bg-primary/80 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> New Rule
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
                    Type
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-base-content/70 uppercase tracking-wider hidden md:table-cell">
                    Category
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-base-content/70 uppercase tracking-wider hidden md:table-cell">
                    Severity
                  </th>
                  <th class="text-left px-6 py-3 text-xs font-medium text-base-content/70 uppercase tracking-wider">
                    Status
                  </th>
                  <th class="text-right px-6 py-3 text-xs font-medium text-base-content/70 uppercase tracking-wider">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody id="detection-rules-stream" phx-update="stream">
                <tr
                  :for={{dom_id, rule} <- @streams.rules}
                  id={dom_id}
                  class={[
                    "border-b-[0.5px] border-base-300 transition-colors",
                    if(rule.enabled,
                      do: "hover:bg-base-200/30",
                      else: "opacity-50 hover:bg-base-200/20"
                    )
                  ]}
                >
                  <td class="px-6 py-4">
                    <div class="font-medium text-sm text-base-content">{rule.name}</div>
                    <div
                      :if={rule.description}
                      class="text-xs text-base-content/50 truncate max-w-[200px]"
                    >
                      {rule.description}
                    </div>
                  </td>
                  <td class="px-6 py-4 hidden sm:table-cell">
                    <.detection_type_badge type={rule.detection_type} />
                  </td>
                  <td class="px-6 py-4 hidden md:table-cell">
                    <span :if={rule.category} class="text-sm text-base-content/80">
                      {rule.category}
                    </span>
                    <span :if={!rule.category} class="text-sm text-base-content/50">—</span>
                  </td>
                  <td class="px-6 py-4 hidden md:table-cell">
                    <.severity_badge severity={rule.severity} />
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
                        patch={~p"/admin/detection-rules/#{rule.id}/edit"}
                        class="inline-flex items-center h-[36px] px-4 text-sm rounded bg-base-200 hover:bg-base-300 text-base-content transition-colors"
                      >
                        <.icon name="hero-pencil" class="size-3.5" />
                      </.link>
                      <button
                        :if={AuthHooks.has_socket_permission?(assigns, "policies:delete")}
                        phx-click="delete"
                        phx-value-id={rule.id}
                        data-confirm={"Delete rule \"#{rule.name}\"? This cannot be undone."}
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
          id="detection-rules-empty"
          class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-12 text-center"
        >
          <.icon name="hero-magnifying-glass" class="size-12 mx-auto text-base-content/30 mb-4" />
          <p class="text-base-content/70 mb-4">No detection rules configured</p>
          <.link
            :if={AuthHooks.has_socket_permission?(assigns, "policies:create")}
            patch={~p"/admin/detection-rules/new"}
            class="inline-flex items-center gap-2 h-[44px] px-6 rounded-lg bg-primary hover:bg-primary/80 text-white text-sm font-medium transition-colors"
          >
            <.icon name="hero-plus" class="size-4" /> Create First Rule
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -------------------------------------------------------------------
  # Preview result component
  # -------------------------------------------------------------------

  attr :result, :any, required: true

  defp preview_result(%{result: {:match, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <div class="flex items-center gap-2 text-sm text-success">
      <.icon name="hero-check-circle" class="size-4" /> {@text}
    </div>
    """
  end

  defp preview_result(%{result: {:no_match, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <div class="flex items-center gap-2 text-sm text-warning">
      <.icon name="hero-x-circle" class="size-4" /> {@text}
    </div>
    """
  end

  defp preview_result(%{result: {:error, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H"""
    <div class="flex items-center gap-2 text-sm text-error">
      <.icon name="hero-exclamation-triangle" class="size-4" /> {@text}
    </div>
    """
  end

  defp preview_result(assigns), do: ~H""

  # -------------------------------------------------------------------
  # Badge components
  # -------------------------------------------------------------------

  attr :type, :atom, required: true

  defp detection_type_badge(%{type: :regex} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-accent/20 text-accent">
      Regex
    </span>
    """
  end

  defp detection_type_badge(%{type: :keyword} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-info/20 text-info">
      Keyword
    </span>
    """
  end

  defp detection_type_badge(%{type: :semantic} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-success/20 text-success">
      Semantic
    </span>
    """
  end

  defp detection_type_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-base-content/10 text-base-content/70">
      {@type}
    </span>
    """
  end

  attr :severity, :atom, required: true

  defp severity_badge(%{severity: :critical} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-error/20 text-error">
      Critical
    </span>
    """
  end

  defp severity_badge(%{severity: :high} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-warning/20 text-warning">
      High
    </span>
    """
  end

  defp severity_badge(%{severity: :medium} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-info/20 text-info">
      Medium
    </span>
    """
  end

  defp severity_badge(%{severity: :low} = assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-base-content/10 text-base-content/70">
      Low
    </span>
    """
  end

  defp severity_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-base-content/10 text-base-content/70">
      {@severity}
    </span>
    """
  end

  attr :enabled, :boolean, required: true

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
