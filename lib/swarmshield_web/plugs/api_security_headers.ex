defmodule SwarmshieldWeb.Plugs.ApiSecurityHeaders do
  @moduledoc """
  Sets security-related response headers for API endpoints.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("cache-control", "no-store")
  end
end
