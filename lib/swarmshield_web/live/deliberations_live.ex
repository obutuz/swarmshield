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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <div>
          <h1 class="text-3xl font-bold text-gray-100">Deliberations</h1>
          <p class="text-gray-400 mt-1">Deliberation engine coming soon.</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
