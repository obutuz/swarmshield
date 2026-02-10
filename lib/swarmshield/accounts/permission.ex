defmodule Swarmshield.Accounts.Permission do
  @moduledoc """
  Permission represents a single action on a resource in resource:action format.

  Examples: "dashboard:view", "agents:create", "policies:delete".
  Stored in database, never hardcoded.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "permissions" do
    field :resource, :string
    field :action, :string
    field :description, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the permission key in "resource:action" format.
  """
  def key(%__MODULE__{resource: resource, action: action}), do: "#{resource}:#{action}"

  @doc """
  Changeset for creating/updating permissions.
  """
  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:resource, :action, :description])
    |> validate_required([:resource, :action])
    |> validate_length(:resource, min: 1, max: 100)
    |> validate_length(:action, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_format(:resource, ~r/^[a-z][a-z0-9_]*$/,
      message:
        "must start with a lowercase letter and contain only lowercase letters, numbers, and underscores"
    )
    |> validate_format(:action, ~r/^[a-z][a-z0-9_]*$/,
      message:
        "must start with a lowercase letter and contain only lowercase letters, numbers, and underscores"
    )
    |> unique_constraint([:resource, :action])
  end
end
