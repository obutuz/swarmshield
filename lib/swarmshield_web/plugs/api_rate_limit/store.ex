defmodule SwarmshieldWeb.Plugs.ApiRateLimit.Store do
  @moduledoc """
  GenServer that owns the ETS table for API rate limiting
  and runs periodic cleanup of expired window entries.
  """

  use GenServer

  @table :api_rate_limit
  @cleanup_interval :timer.seconds(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    schedule_cleanup()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    window_seconds =
      Application.get_env(:swarmshield, SwarmshieldWeb.Plugs.ApiRateLimit, [])
      |> Keyword.get(:window_seconds, 60)

    current_window = System.system_time(:second) |> div(window_seconds)

    try do
      :ets.select_delete(@table, [
        {{:"$1", :_}, [{:<, {:element, 2, :"$1"}, current_window}], [true]}
      ])
    rescue
      ArgumentError -> :ok
    end

    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
