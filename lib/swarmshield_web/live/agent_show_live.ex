defmodule SwarmshieldWeb.AgentShowLive do
  @moduledoc "Single agent detail view. Full implementation in Phase 6."
  use SwarmshieldWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Agent Details")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <div>
          <h1 class="text-3xl font-bold text-gray-100">Agent Details</h1>
          <p class="text-gray-400 mt-1">Agent detail view coming soon.</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
