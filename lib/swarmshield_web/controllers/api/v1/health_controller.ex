defmodule SwarmshieldWeb.Api.V1.HealthController do
  use SwarmshieldWeb, :controller

  alias Ecto.Adapters.SQL
  alias Swarmshield.Repo

  @db_timeout 5_000

  def index(conn, _params) do
    case check_database() do
      :ok ->
        conn
        |> put_status(200)
        |> json(%{
          status: "ok",
          version: app_version(),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:error, reason} ->
        conn
        |> put_status(503)
        |> json(%{
          status: "degraded",
          error: "database_unreachable",
          detail: to_string(reason),
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        })
    end
  end

  defp check_database do
    case SQL.query(Repo, "SELECT 1", [], timeout: @db_timeout) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp app_version do
    case Application.spec(:swarmshield, :vsn) do
      nil -> "0.1.0"
      vsn -> to_string(vsn)
    end
  end
end
