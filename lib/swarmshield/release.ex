defmodule Swarmshield.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix installed.
  """
  @app :swarmshield

  def migrate do
    IO.puts("Starting migration process for SwarmShield...")

    Application.load(@app)

    for app <- [:crypto, :ssl, :postgrex, :ecto_sql] do
      case Application.ensure_all_started(app) do
        {:ok, _} -> IO.puts("Started #{app}")
        {:error, error} -> IO.puts("Failed to start #{app}: #{inspect(error)}")
      end
    end

    for repo <- repos() do
      IO.puts("Running migrations for #{inspect(repo)}...")

      case Ecto.Migrator.with_repo(repo, fn repo ->
             Ecto.Migrator.run(repo, :up, all: true)
           end) do
        {:ok, migrations, _} ->
          IO.puts("Migrations completed. Applied #{length(migrations)} migrations.")

        {:error, error} ->
          IO.puts("Migration failed: #{inspect(error)}")
          raise "Migration failed: #{inspect(error)}"
      end
    end
  rescue
    error ->
      IO.puts("CRITICAL ERROR during migration: #{inspect(error)}")
      reraise error, __STACKTRACE__
  end

  def rollback(repo, version) do
    Application.load(@app)
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  def seed do
    Application.load(@app)

    for app <- [:crypto, :ssl, :postgrex, :ecto_sql] do
      Application.ensure_all_started(app)
    end

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          seed_path =
            case :code.priv_dir(@app) do
              {:error, _} -> "priv/repo/seeds.exs"
              path -> Path.join(to_string(path), "repo/seeds.exs")
            end

          if File.exists?(seed_path) do
            IO.puts("Running seeds from #{seed_path}...")
            Code.eval_file(seed_path)
            IO.puts("Seeds completed.")
          else
            IO.puts("No seed file found at #{seed_path}")
          end
        end)
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end
end
