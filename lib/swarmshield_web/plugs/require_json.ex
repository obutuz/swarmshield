defmodule SwarmshieldWeb.Plugs.RequireJson do
  @moduledoc """
  Validates that requests with bodies (POST, PUT, PATCH) have
  Content-Type: application/json. Returns 415 Unsupported Media Type otherwise.

  GET, DELETE, HEAD, and OPTIONS requests pass through unconditionally.
  """

  @behaviour Plug

  import Plug.Conn

  @methods_requiring_body ~w(POST PUT PATCH)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: method} = conn, _opts) when method in @methods_requiring_body do
    case get_req_header(conn, "content-type") do
      [content_type] ->
        if String.starts_with?(content_type, "application/json") do
          conn
        else
          respond_unsupported_media_type(conn)
        end

      [] ->
        respond_unsupported_media_type(conn)

      _multiple ->
        respond_unsupported_media_type(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp respond_unsupported_media_type(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      415,
      Jason.encode!(%{
        error: "unsupported_media_type",
        message: "Content-Type must be application/json"
      })
    )
    |> halt()
  end
end
