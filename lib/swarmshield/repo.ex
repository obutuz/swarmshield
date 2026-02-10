defmodule Swarmshield.Repo do
  use Ecto.Repo,
    otp_app: :swarmshield,
    adapter: Ecto.Adapters.Postgres
end
