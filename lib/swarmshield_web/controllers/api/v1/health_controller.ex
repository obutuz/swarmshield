defmodule SwarmshieldWeb.Api.V1.HealthController do
  use SwarmshieldWeb, :controller

  @version Mix.Project.config()[:version]

  def index(conn, _params) do
    conn
    |> put_status(200)
    |> json(%{status: "ok", version: @version})
  end
end
