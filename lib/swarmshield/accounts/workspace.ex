defmodule Swarmshield.Accounts.Workspace do
  @moduledoc """
  Workspace is the top-level isolation boundary in SwarmShield.

  All domain entities (agents, events, policies, deliberations) are scoped
  to a workspace. Users can belong to multiple workspaces with different roles.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :api_key_hash, :string, redact: true
    field :api_key_prefix, :string
    field :status, Ecto.Enum, values: [:active, :suspended, :archived], default: :active
    field :settings, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  User-facing changeset for creating/updating workspaces.
  Never includes sensitive fields like api_key_hash.
  """
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :slug, :description, :status, :settings])
    |> validate_required([:name, :slug])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:slug, min: 1, max: 255)
    |> validate_length(:description, max: 1000)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$/,
      message:
        "must contain only lowercase letters, numbers, and hyphens, and cannot start or end with a hyphen"
    )
    |> unique_constraint(:slug)
  end

  @doc """
  Internal changeset for setting the API key hash. Only used by system code.
  """
  def api_key_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:api_key_hash, :api_key_prefix])
    |> validate_required([:api_key_hash, :api_key_prefix])
  end
end
