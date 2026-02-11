defmodule SwarmshieldWeb.WorkspaceSelectorLive do
  @moduledoc """
  Displays a list of workspaces the user belongs to and allows selection.
  Stub implementation - full workspace switching in a future story.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Select Workspace")}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    user = socket.assigns.current_scope.user
    {workspaces, _count} = Accounts.list_user_workspaces(user, page_size: 50)

    {:noreply, assign(socket, :workspaces, workspaces)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-[60vh] flex items-center justify-center px-4">
        <div class="w-full max-w-lg">
          <div class="bg-gray-800 border border-gray-700 rounded-lg p-6 sm:p-8">
            <div class="text-center mb-6">
              <h1 class="text-2xl sm:text-3xl font-bold text-gray-100">Select Workspace</h1>
              <p class="text-gray-400 mt-2">Choose a workspace to continue.</p>
            </div>

            <div :if={@workspaces == []} class="text-center py-8">
              <p class="text-gray-400 mb-4">You don't belong to any workspaces yet.</p>
              <.link
                navigate={~p"/onboarding"}
                class="h-[44px] px-6 bg-blue-600 hover:bg-blue-700 text-white rounded-lg inline-flex items-center"
              >
                Create a Workspace
              </.link>
            </div>

            <div :if={@workspaces != []} class="space-y-3">
              <div
                :for={uwr <- @workspaces}
                class="flex items-center justify-between p-4 bg-gray-900 border border-gray-700 rounded-lg hover:border-blue-500 transition-colors"
              >
                <div>
                  <p class="text-gray-100 font-medium">{uwr.workspace.name}</p>
                  <p class="text-gray-500 text-sm">{uwr.role.name}</p>
                </div>
                <.link
                  navigate={~p"/"}
                  class="h-[36px] px-4 text-sm bg-blue-600 hover:bg-blue-700 text-white rounded inline-flex items-center"
                >
                  Select
                </.link>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
