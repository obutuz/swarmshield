defmodule Swarmshield.Accounts.RolePermission do
  @moduledoc """
  Many-to-many join between Role and Permission.

  A role has many permissions, and a permission can belong to many roles.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "role_permissions" do
    belongs_to :role, Swarmshield.Accounts.Role
    belongs_to :permission, Swarmshield.Accounts.Permission

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating role-permission associations.
  """
  def changeset(role_permission, attrs) do
    role_permission
    |> cast(attrs, [:role_id, :permission_id])
    |> validate_required([:role_id, :permission_id])
    |> foreign_key_constraint(:role_id)
    |> foreign_key_constraint(:permission_id)
    |> unique_constraint([:role_id, :permission_id])
  end
end
