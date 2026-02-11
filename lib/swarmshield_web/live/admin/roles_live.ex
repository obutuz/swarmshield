defmodule SwarmshieldWeb.Admin.RolesLive do
  @moduledoc "Role management admin. Full implementation in Phase 7."
  use SwarmshieldWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Manage Roles")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <div>
          <h1 class="text-3xl font-bold text-gray-100">Manage Roles</h1>
          <p class="text-gray-400 mt-1">Role management coming soon.</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
