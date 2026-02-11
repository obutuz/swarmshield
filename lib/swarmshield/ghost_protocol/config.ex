defmodule Swarmshield.GhostProtocol.Config do
  @moduledoc """
  GhostProtocolConfig stores retention/wipe policies for the GhostProtocol
  feature - agents do expert work then vanish completely.

  Each config defines wipe strategy (immediate/delayed/scheduled), which
  fields to wipe, crypto shred option, and max session duration. Workflows
  optionally reference a config via ghost_protocol_config_id (NULL =
  non-ephemeral). This is a flagship security feature of SwarmShield.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @wipe_strategies [:immediate, :delayed, :scheduled]

  @allowed_wipe_fields ~w(
    input_content
    deliberation_messages
    metadata
    initial_assessment
    payload
  )

  schema "ghost_protocol_configs" do
    field :name, :string
    field :slug, :string
    field :wipe_strategy, Ecto.Enum, values: @wipe_strategies
    field :wipe_delay_seconds, :integer, default: 0
    field :wipe_fields, {:array, :string}, default: []
    field :retain_verdict, :boolean, default: true
    field :retain_audit, :boolean, default: true
    field :max_session_duration_seconds, :integer
    field :auto_terminate_on_expiry, :boolean, default: true
    field :crypto_shred, :boolean, default: false
    field :enabled, :boolean, default: true
    field :metadata, :map, default: %{}

    belongs_to :workspace, Swarmshield.Accounts.Workspace

    has_many :workflows, Swarmshield.Deliberation.Workflow, foreign_key: :ghost_protocol_config_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the list of allowed wipe field names.
  """
  def allowed_wipe_fields, do: @allowed_wipe_fields

  @doc """
  User-facing changeset for creating/updating GhostProtocol configs.

  workspace_id is set server-side and NEVER cast from user input.
  """
  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :name,
      :slug,
      :wipe_strategy,
      :wipe_delay_seconds,
      :wipe_fields,
      :retain_verdict,
      :retain_audit,
      :max_session_duration_seconds,
      :auto_terminate_on_expiry,
      :crypto_shred,
      :enabled,
      :metadata
    ])
    |> validate_required([:name, :wipe_strategy, :max_session_duration_seconds])
    |> validate_length(:name, min: 1, max: 255)
    |> maybe_generate_slug()
    |> validate_length(:slug, min: 1, max: 255)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$/,
      message:
        "must contain only lowercase letters, numbers, and hyphens, " <>
          "and cannot start or end with a hyphen"
    )
    |> validate_number(:max_session_duration_seconds,
      greater_than_or_equal_to: 10,
      less_than_or_equal_to: 3600
    )
    |> validate_number(:wipe_delay_seconds,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 86_400
    )
    |> validate_wipe_delay_for_strategy()
    |> validate_wipe_fields()
    |> validate_retain_verdict()
    |> validate_retain_audit()
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :slug],
      error_key: :slug,
      message: "a config with this slug already exists in this workspace"
    )
  end

  # Auto-generate slug from name if not provided
  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        case get_change(changeset, :name) do
          nil ->
            changeset

          name ->
            slug =
              name
              |> String.downcase()
              |> String.replace(~r/[^a-z0-9]+/, "-")
              |> String.replace(~r/^-|-$/, "")
              |> String.slice(0, 255)

            put_change(changeset, :slug, slug)
        end

      _slug ->
        changeset
    end
  end

  # Validates wipe_delay_seconds > 0 when strategy is :delayed or :scheduled
  defp validate_wipe_delay_for_strategy(changeset) do
    strategy = get_field(changeset, :wipe_strategy)
    delay = get_field(changeset, :wipe_delay_seconds)

    case {strategy, delay} do
      {:delayed, d} when is_integer(d) and d <= 0 ->
        add_error(
          changeset,
          :wipe_delay_seconds,
          "must be greater than 0 when wipe_strategy is delayed"
        )

      {:scheduled, d} when is_integer(d) and d <= 0 ->
        add_error(
          changeset,
          :wipe_delay_seconds,
          "must be greater than 0 when wipe_strategy is scheduled"
        )

      _ ->
        changeset
    end
  end

  # Validates wipe_fields entries against the allowed field names
  defp validate_wipe_fields(changeset) do
    case get_change(changeset, :wipe_fields) do
      nil ->
        changeset

      fields when is_list(fields) ->
        invalid_fields = Enum.reject(fields, &(&1 in @allowed_wipe_fields))

        case invalid_fields do
          [] ->
            changeset

          invalid ->
            add_error(
              changeset,
              :wipe_fields,
              "contains invalid field names: #{Enum.join(invalid, ", ")}. " <>
                "Allowed: #{Enum.join(@allowed_wipe_fields, ", ")}"
            )
        end

      _other ->
        changeset
    end
  end

  # Verdicts must always be retained - this is a security requirement
  defp validate_retain_verdict(changeset) do
    case get_field(changeset, :retain_verdict) do
      false ->
        add_error(changeset, :retain_verdict, "verdicts must always be retained for compliance")

      _ ->
        changeset
    end
  end

  # Audit trail must always be retained - this is a security requirement
  defp validate_retain_audit(changeset) do
    case get_field(changeset, :retain_audit) do
      false ->
        add_error(changeset, :retain_audit, "audit trail must always be retained for compliance")

      _ ->
        changeset
    end
  end
end
