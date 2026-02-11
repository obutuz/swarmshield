defmodule SwarmshieldWeb.WorkspaceSelectorLive do
  @moduledoc """
  Displays a list of workspaces the user belongs to and allows selection.

  Selection works via phx-trigger-action: clicking "Select" sets the workspace_id
  in a hidden form, which POSTs to WorkspaceSessionController to set the Plug session.

  Auto-select: if the user has exactly 1 workspace, selection is triggered automatically.
  System owners see ALL workspaces (not just their memberships).
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Select Workspace")
     |> assign(:trigger_action, false)
     |> assign(:selected_workspace_id, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    user = socket.assigns.current_scope.user
    workspaces = load_workspaces(user)

    socket = assign(socket, :workspaces, workspaces)

    # Auto-select if exactly 1 workspace
    case workspaces do
      [single] ->
        workspace_id = extract_workspace_id(single)

        {:noreply,
         socket
         |> assign(:selected_workspace_id, workspace_id)
         |> assign(:trigger_action, true)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_workspace", %{"workspace-id" => workspace_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_workspace_id, workspace_id)
     |> assign(:trigger_action, true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-[60vh] flex items-center justify-center px-4">
        <div class="w-full max-w-lg">
          <div class="bg-base-100 border-[0.5px] border-base-300 rounded-lg p-6 sm:p-8">
            <div class="text-center mb-6">
              <h1 class="text-2xl sm:text-3xl font-bold text-base-content">Select Workspace</h1>
              <p class="text-base-content/70 mt-2">Choose a workspace to continue.</p>
            </div>

            <div :if={@workspaces == []} class="text-center py-8">
              <p class="text-base-content/70 mb-4">You don't belong to any workspaces yet.</p>
              <.link
                navigate={~p"/onboarding"}
                class="h-[44px] px-6 bg-primary hover:bg-primary/80 text-white rounded-lg inline-flex items-center"
              >
                Create a Workspace
              </.link>
            </div>

            <div :if={@workspaces != []} class="space-y-3">
              <.workspace_card
                :for={item <- @workspaces}
                item={item}
                is_system_owner={@current_scope.user.is_system_owner}
              />
            </div>

            <%!-- Hidden form for phx-trigger-action POST to set session --%>
            <.form
              :if={@selected_workspace_id}
              for={%{}}
              as={:workspace}
              action={~p"/set-workspace"}
              phx-trigger-action={@trigger_action}
              method="post"
            >
              <input type="hidden" name="workspace_id" value={@selected_workspace_id} />
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :item, :any, required: true
  attr :is_system_owner, :boolean, default: false

  defp workspace_card(%{is_system_owner: true} = assigns) do
    # System owners see raw Workspace structs (no UWR wrapper)
    ~H"""
    <div class="flex items-center justify-between p-4 bg-base-200 border-[0.5px] border-base-300 rounded-lg hover:border-primary transition-colors">
      <div>
        <p class="text-base-content font-medium">{@item.name}</p>
        <p class="text-base-content/50 text-sm">System Owner</p>
      </div>
      <button
        type="button"
        phx-click="select_workspace"
        phx-value-workspace-id={@item.id}
        class="h-[36px] px-4 text-sm bg-primary hover:bg-primary/80 text-white rounded inline-flex items-center"
      >
        Select
      </button>
    </div>
    """
  end

  defp workspace_card(assigns) do
    # Regular users see UWR structs with preloaded workspace + role
    ~H"""
    <div class="flex items-center justify-between p-4 bg-base-200 border-[0.5px] border-base-300 rounded-lg hover:border-primary transition-colors">
      <div>
        <p class="text-base-content font-medium">{@item.workspace.name}</p>
        <p class="text-base-content/50 text-sm">{@item.role.name}</p>
      </div>
      <button
        type="button"
        phx-click="select_workspace"
        phx-value-workspace-id={@item.workspace_id}
        class="h-[36px] px-4 text-sm bg-primary hover:bg-primary/80 text-white rounded inline-flex items-center"
      >
        Select
      </button>
    </div>
    """
  end

  # System owners see ALL workspaces; regular users see their memberships
  defp load_workspaces(%{is_system_owner: true} = _user) do
    {workspaces, _count} = Accounts.list_workspaces(page_size: 50)
    workspaces
  end

  defp load_workspaces(user) do
    {workspaces, _count} = Accounts.list_user_workspaces(user, page_size: 50)
    workspaces
  end

  # Extract workspace_id from either a Workspace struct or UWR struct
  defp extract_workspace_id(%Accounts.Workspace{id: id}), do: id
  defp extract_workspace_id(%{workspace_id: id}), do: id
end
