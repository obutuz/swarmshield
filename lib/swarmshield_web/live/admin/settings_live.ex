defmodule SwarmshieldWeb.Admin.SettingsLive do
  @moduledoc "Workspace settings admin. Full implementation in Phase 7."
  use SwarmshieldWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Workspace Settings")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_settings}
    >
      <div class="space-y-6">
        <div>
          <h1 class="text-3xl font-bold">Workspace Settings</h1>
          <p class="text-base-content/60 mt-1">Workspace configuration coming soon.</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
