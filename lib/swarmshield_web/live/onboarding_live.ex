defmodule SwarmshieldWeb.OnboardingLive do
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Accounts
  alias Swarmshield.Accounts.Workspace

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-[60vh] flex items-center justify-center px-4">
        <div class="w-full max-w-lg">
          <%= case @step do %>
            <% :form -> %>
              <.render_form_step form={@form} slug_preview={@slug_preview} />
            <% :success -> %>
              <.render_success_step
                workspace_name={@workspace_name}
                raw_api_key={@raw_api_key}
                key_copied={@key_copied}
              />
          <% end %>
        </div>
      </div>

      <%!-- Hidden form for phx-trigger-action POST to set workspace session --%>
      <.form
        :if={@created_workspace_id}
        for={%{}}
        as={:workspace}
        action={~p"/set-workspace"}
        phx-trigger-action={@trigger_action}
        method="post"
      >
        <input type="hidden" name="workspace_id" value={@created_workspace_id} />
      </.form>
    </Layouts.app>
    """
  end

  defp render_form_step(assigns) do
    ~H"""
    <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-6 sm:p-8">
      <div class="text-center mb-6">
        <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-primary/20 mb-4">
          <.icon name="hero-building-office-2" class="h-6 w-6 text-info" />
        </div>
        <h1 class="text-2xl sm:text-3xl font-bold text-base-content">Create Your Workspace</h1>
        <p class="text-base-content/70 mt-2">
          Set up your first workspace to start protecting your AI agents.
        </p>
      </div>

      <.form for={@form} id="onboarding-form" phx-change="validate" phx-submit="save">
        <div class="space-y-4">
          <div>
            <label for="workspace_name" class="block text-sm font-medium text-base-content/80 mb-1">
              Workspace Name
            </label>
            <input
              type="text"
              name={@form[:name].name}
              id="workspace_name"
              value={@form[:name].value}
              phx-debounce="300"
              placeholder="e.g. Acme Corp"
              autocomplete="organization"
              class="w-full h-[44px] bg-base-200 border-[0.5px] border-base-300 rounded-lg text-base-content focus:border-primary focus:ring-1 focus:ring-primary px-3 placeholder-gray-500"
            />
            <.field_error field={@form[:name]} />
            <p :if={@slug_preview != ""} class="text-sm text-base-content/50 mt-1">
              Slug: {@slug_preview}
            </p>
          </div>

          <div>
            <label
              for="workspace_description"
              class="block text-sm font-medium text-base-content/80 mb-1"
            >
              Description <span class="text-base-content/50">(optional)</span>
            </label>
            <textarea
              name={@form[:description].name}
              id="workspace_description"
              phx-debounce="300"
              rows="3"
              placeholder="What will this workspace be used for?"
              class="w-full bg-base-200 border-[0.5px] border-base-300 rounded-lg text-base-content focus:border-primary focus:ring-1 focus:ring-primary px-3 py-2 placeholder-gray-500 resize-none"
            >{@form[:description].value}</textarea>
            <.field_error field={@form[:description]} />
          </div>

          <div>
            <.field_error field={@form[:slug]} />
          </div>

          <div class="pt-2">
            <button
              type="submit"
              phx-disable-with="Creating workspace..."
              class="w-full h-[44px] bg-primary hover:bg-primary/80 text-white font-medium rounded-lg transition-colors"
            >
              Create Workspace
            </button>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  defp render_success_step(assigns) do
    ~H"""
    <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-6 sm:p-8">
      <div class="text-center mb-6">
        <div class="inline-flex items-center justify-center w-12 h-12 rounded-full bg-success/20 mb-4">
          <.icon name="hero-check-circle" class="h-6 w-6 text-success" />
        </div>
        <h1 class="text-2xl sm:text-3xl font-bold text-base-content">Workspace Created!</h1>
        <p class="text-base-content/70 mt-2">
          <strong class="text-base-content">{@workspace_name}</strong>
          is ready. Save your API key below — it won't be shown again.
        </p>
      </div>

      <div class="space-y-4">
        <div>
          <label class="block text-sm font-medium text-base-content/80 mb-1">
            Your API Key
          </label>
          <div class="bg-yellow-400/10 border-[0.5px] border-warning/30 rounded-lg p-3 mb-2">
            <p class="text-warning text-xs font-medium mb-1">
              Save this key now — you will not be able to see it again.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <input
              type="text"
              readonly
              value={@raw_api_key}
              id="api-key-display"
              class="flex-1 h-[44px] bg-base-200 border-[0.5px] border-base-300 rounded-lg text-base-content px-3 font-mono text-sm select-all"
              onclick="this.select()"
            />
            <button
              type="button"
              id="copy-api-key-btn"
              phx-click="copy_key"
              class="h-[44px] px-4 bg-base-200 hover:bg-base-300 text-base-content rounded-lg transition-colors whitespace-nowrap"
            >
              {if @key_copied, do: "Copied!", else: "Copy"}
            </button>
          </div>
        </div>

        <div class="pt-2">
          <button
            type="button"
            phx-click="continue_to_dashboard"
            class="w-full h-[44px] bg-primary hover:bg-primary/80 text-white font-medium rounded-lg transition-colors"
          >
            Continue to Dashboard
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp field_error(assigns) do
    ~H"""
    <div
      :for={msg <- Enum.map(@field.errors, &translate_error/1)}
      class="text-error text-sm mt-1"
    >
      {msg}
    </div>
    """
  end

  # --- Lifecycle ---

  @impl true
  def mount(_params, _session, socket) do
    # Iron Law: NO database queries in mount
    {:ok,
     socket
     |> assign(:step, :form)
     |> assign(:slug_preview, "")
     |> assign(:workspace_name, "")
     |> assign(:raw_api_key, "")
     |> assign(:key_copied, false)
     |> assign(:created_workspace_id, nil)
     |> assign(:trigger_action, false)
     |> assign_form(Accounts.change_workspace(%Workspace{}))}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.list_user_workspaces(user, page_size: 1) do
      {_, 0} ->
        {:noreply, socket}

      _ ->
        {:noreply,
         socket
         |> put_flash(:info, "You already have a workspace.")
         |> push_navigate(to: "/select-workspace")}
    end
  end

  # --- Events ---

  @impl true
  def handle_event("validate", %{"workspace" => params}, socket) do
    slug = Accounts.generate_slug(params["name"] || "")
    params = Map.put(params, "slug", slug)

    changeset =
      Accounts.change_workspace(%Workspace{}, params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:slug_preview, slug)
     |> assign_form(changeset)}
  end

  def handle_event("save", %{"workspace" => params}, socket) do
    user = socket.assigns.current_scope.user
    slug = Accounts.generate_slug(params["name"] || "")
    workspace_attrs = Map.put(params, "slug", slug)

    case Accounts.onboard_workspace(user, workspace_attrs) do
      {:ok, %{workspace: workspace, raw_api_key: raw_key}} ->
        {:noreply,
         socket
         |> assign(:step, :success)
         |> assign(:workspace_name, workspace.name)
         |> assign(:raw_api_key, raw_key)
         |> assign(:key_copied, false)
         |> assign(:created_workspace_id, workspace.id)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Something went wrong. Please try again.")
         |> assign_form(Accounts.change_workspace(%Workspace{}, params))}
    end
  end

  def handle_event("copy_key", _params, socket) do
    {:noreply,
     socket
     |> assign(:key_copied, true)
     |> push_event("clipboard:copy", %{text: socket.assigns.raw_api_key})}
  end

  def handle_event("continue_to_dashboard", _params, socket) do
    {:noreply, assign(socket, :trigger_action, true)}
  end

  # --- Helpers ---

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "workspace"))
  end
end
