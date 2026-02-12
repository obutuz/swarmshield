defmodule Swarmshield.Repo.Migrations.AlterErrorMessageToText do
  use Ecto.Migration

  def change do
    alter table(:agent_instances) do
      modify :error_message, :text, from: :string
    end

    alter table(:analysis_sessions) do
      modify :error_message, :text, from: :string
    end
  end
end
