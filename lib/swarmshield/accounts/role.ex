defmodule Swarmshield.Accounts.Role do
  @moduledoc """
  Role defines a named set of permissions.

  Roles are database records, NOT hardcoded. Default roles (super_admin, admin,
  analyst, viewer) are seeded but can be customized per workspace.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "roles" do
    field :name, :string
    field :description, :string
    field :is_system, :boolean, default: false

    has_many :role_permissions, Swarmshield.Accounts.RolePermission
    has_many :permissions, through: [:role_permissions, :permission]

    timestamps(type: :utc_datetime)
  end

  @doc """
  User-facing changeset for creating/updating roles.
  Never includes is_system - that is only set by seed/system code.
  """
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:description, max: 500)
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message:
        "must start with a lowercase letter and contain only lowercase letters, numbers, and underscores"
    )
    |> unique_constraint(:name)
  end

  @doc """
  Internal changeset for setting system flag. Only used by seed/system code.
  """
  def system_changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :description, :is_system])
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-z][a-z0-9_]*$/,
      message:
        "must start with a lowercase letter and contain only lowercase letters, numbers, and underscores"
    )
    |> unique_constraint(:name)
  end
end
