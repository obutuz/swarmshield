defmodule Swarmshield.Repo.Migrations.AddIsSystemOwnerToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :is_system_owner, :boolean, default: false, null: false
    end

    # Set obutuz@gmail.com as system owner
    execute(
      "UPDATE users SET is_system_owner = true WHERE email = 'obutuz@gmail.com'",
      "UPDATE users SET is_system_owner = false WHERE email = 'obutuz@gmail.com'"
    )
  end
end
