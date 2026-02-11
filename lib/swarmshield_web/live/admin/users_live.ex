defmodule SwarmshieldWeb.Admin.UsersLive do
  @moduledoc "User management admin. Full implementation in Phase 7."
  use SwarmshieldWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Manage Users")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_users}
    >
      <div class="space-y-6">
        <div>
          <h1 class="text-3xl font-bold">Manage Users</h1>
          <p class="text-base-content/60 mt-1">User management coming soon.</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
