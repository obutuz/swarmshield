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
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_roles}
    >
      <div class="space-y-6">
        <div>
          <h1 class="text-3xl font-bold">Manage Roles</h1>
          <p class="text-base-content/60 mt-1">Role management coming soon.</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
