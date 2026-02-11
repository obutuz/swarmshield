defmodule SwarmshieldWeb.Plugs.CorsHeaders do
  @moduledoc """
  Handles CORS preflight (OPTIONS) requests and sets response headers
  for cross-origin API access. Origins are configurable via application env.

  ## Configuration

      config :swarmshield, SwarmshieldWeb.Plugs.CorsHeaders,
        allowed_origins: ["https://app.swarmshield.io"],
        max_age: 86400
  """

  @behaviour Plug

  import Plug.Conn

  @allowed_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  @allowed_headers "authorization, content-type, accept, origin, x-request-id"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "OPTIONS"} = conn, _opts) do
    conn
    |> set_cors_headers()
    |> send_resp(204, "")
    |> halt()
  end

  def call(conn, _opts), do: set_cors_headers(conn)

  defp set_cors_headers(conn) do
    origin = get_allowed_origin(conn)

    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", @allowed_methods)
    |> put_resp_header("access-control-allow-headers", @allowed_headers)
    |> put_resp_header("access-control-max-age", to_string(max_age()))
  end

  defp get_allowed_origin(conn) do
    request_origin = get_req_header(conn, "origin") |> List.first("")

    case allowed_origins() do
      ["*"] ->
        "*"

      origins when is_list(origins) ->
        if request_origin in origins, do: request_origin, else: List.first(origins, "")
    end
  end

  defp allowed_origins do
    Application.get_env(:swarmshield, __MODULE__, [])
    |> Keyword.get(:allowed_origins, ["*"])
  end

  defp max_age do
    Application.get_env(:swarmshield, __MODULE__, [])
    |> Keyword.get(:max_age, 86_400)
  end
end
