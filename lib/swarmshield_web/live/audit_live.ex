defmodule SwarmshieldWeb.AuditLive do
  @moduledoc "Audit log viewer. Full implementation in Phase 6."
  use SwarmshieldWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Audit Log")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:audit}
    >
      <div class="space-y-6">
        <div>
          <h1 class="text-3xl font-bold">Audit Log</h1>
          <p class="text-base-content/60 mt-1">Audit trail viewer coming soon.</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
