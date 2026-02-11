defmodule Swarmshield.Accounts.AuditEntry do
  @moduledoc """
  Immutable, insert-only audit log.

  Every significant action in the system creates an audit entry. Audit entries
  are never updated or deleted - they are critical for security compliance.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_entries" do
    field :action, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :actor_email, :string
    field :metadata, :map, default: %{}
    field :ip_address, :string
    field :user_agent, :string

    belongs_to :actor, Swarmshield.Accounts.User
    belongs_to :workspace, Swarmshield.Accounts.Workspace

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @sensitive_keys ~w(password api_key token secret hashed_password api_key_hash)

  @doc """
  Changeset for creating audit entries. Insert-only - no update changeset exists.
  Metadata is sanitized to remove sensitive fields.
  """
  def create_changeset(audit_entry, attrs) do
    audit_entry
    |> cast(attrs, [
      :action,
      :resource_type,
      :resource_id,
      :actor_id,
      :actor_email,
      :workspace_id,
      :metadata,
      :ip_address,
      :user_agent
    ])
    |> validate_required([:action, :resource_type])
    |> validate_length(:action, max: 255)
    |> validate_length(:resource_type, max: 255)
    |> validate_length(:actor_email, max: 255)
    |> validate_length(:ip_address, max: 45)
    |> validate_length(:user_agent, max: 500)
    |> sanitize_metadata()
    |> foreign_key_constraint(:actor_id)
    |> foreign_key_constraint(:workspace_id)
  end

  defp sanitize_metadata(changeset) do
    case get_change(changeset, :metadata) do
      nil -> changeset
      metadata when is_map(metadata) -> put_change(changeset, :metadata, do_sanitize(metadata))
      _other -> changeset
    end
  end

  defp do_sanitize(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_map(value) ->
        if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, do_sanitize(value)}

      {key, _value} when is_binary(key) ->
        if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, map[key]}

      {key, value} ->
        {key, value}
    end)
  end

  defp sensitive_key?(key) when is_binary(key) do
    downcased = String.downcase(key)
    Enum.any?(@sensitive_keys, &String.contains?(downcased, &1))
  end

  defp sensitive_key?(_), do: false
end
