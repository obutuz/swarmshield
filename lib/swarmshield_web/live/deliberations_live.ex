defmodule SwarmshieldWeb.DeliberationsLive do
  @moduledoc "Deliberation sessions list. Full implementation in Phase 6."
  use SwarmshieldWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Deliberations")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:deliberations}
    >
      <div class="space-y-6">
        <div>
          <h1 class="text-3xl font-bold">Deliberations</h1>
          <p class="text-base-content/60 mt-1">Deliberation engine coming soon.</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
