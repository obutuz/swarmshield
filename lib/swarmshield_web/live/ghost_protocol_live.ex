defmodule SwarmshieldWeb.GhostProtocolLive do
  @moduledoc "GhostProtocol dashboard. Full implementation in Phase 6 (DASH-009)."
  use SwarmshieldWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "GhostProtocol")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:ghost_protocol}
    >
      <div class="space-y-6">
        <div>
          <h1 class="text-3xl font-bold">GhostProtocol</h1>
          <p class="text-base-content/60 mt-1">Ephemeral session management coming soon.</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
