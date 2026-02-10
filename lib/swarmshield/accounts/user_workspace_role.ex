defmodule Swarmshield.Accounts.UserWorkspaceRole do
  @moduledoc """
  Junction table linking a user to a workspace with a specific role.

  This is the core RBAC assignment - a user has one role within the context
  of a specific workspace. The unique constraint on [user_id, workspace_id]
  ensures one role per user per workspace.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_workspace_roles" do
    belongs_to :user, Swarmshield.Accounts.User
    belongs_to :workspace, Swarmshield.Accounts.Workspace
    belongs_to :role, Swarmshield.Accounts.Role

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating/updating user-workspace-role assignments.
  """
  def changeset(user_workspace_role, attrs) do
    user_workspace_role
    |> cast(attrs, [:user_id, :workspace_id, :role_id])
    |> validate_required([:user_id, :workspace_id, :role_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:role_id)
    |> unique_constraint([:user_id, :workspace_id],
      message: "user already has a role in this workspace"
    )
  end
end
