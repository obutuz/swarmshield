defmodule SwarmshieldWeb.LiveHelpers do
  @moduledoc """
  Shared helper functions for LiveViews.

  Contains common formatting and utility functions used across
  multiple dashboard LiveViews to avoid duplication.
  """

  @doc """
  Returns true if the session has a GhostProtocol configuration,
  indicating it's an ephemeral session.
  """
  @spec ephemeral?(map()) :: boolean()
  def ephemeral?(%{workflow: %{ghost_protocol_config: config}}) when not is_nil(config), do: true
  def ephemeral?(_session), do: false

  @doc """
  Formats a DateTime or NaiveDateTime as a human-readable relative time string.

  Returns strings like "Just now", "5m ago", "3h ago", "2d ago",
  or a formatted date for older timestamps.
  """
  @spec format_relative_time(DateTime.t() | NaiveDateTime.t() | nil) :: String.t()
  def format_relative_time(nil), do: "Never"

  def format_relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(:second), dt, :second)

    cond do
      diff < 60 -> "Just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %d, %Y")
    end
  end

  def format_relative_time(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> format_relative_time()
  end
end
