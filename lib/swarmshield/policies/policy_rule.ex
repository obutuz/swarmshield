defmodule Swarmshield.Policies.PolicyRule do
  @moduledoc """
  PolicyRule defines an allow/flag/block rule for evaluating agent events.

  Rules are ETS-cached for sub-millisecond evaluation. Each rule has a type
  (rate_limit, pattern_match, blocklist, allowlist, payload_size, custom)
  and configuration stored in the `config` map field.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @rule_types [:rate_limit, :pattern_match, :blocklist, :allowlist, :payload_size, :custom]
  @actions [:allow, :flag, :block]

  schema "policy_rules" do
    field :name, :string
    field :description, :string
    field :rule_type, Ecto.Enum, values: @rule_types
    field :action, Ecto.Enum, values: @actions
    field :priority, :integer, default: 0
    field :enabled, :boolean, default: true
    field :config, :map
    field :applies_to_agent_types, {:array, :string}, default: []
    field :applies_to_event_types, {:array, :string}, default: []

    belongs_to :workspace, Swarmshield.Accounts.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc """
  User-facing changeset for creating/updating policy rules.
  workspace_id is set server-side, never from user input.
  """
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :name,
      :description,
      :rule_type,
      :action,
      :priority,
      :enabled,
      :config,
      :applies_to_agent_types,
      :applies_to_event_types
    ])
    |> validate_required([:name, :rule_type, :action, :config])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_config_for_rule_type()
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :name])
  end

  defp validate_config_for_rule_type(changeset) do
    rule_type = get_field(changeset, :rule_type)
    config = get_field(changeset, :config)

    case {rule_type, config} do
      {_, nil} ->
        changeset

      {:rate_limit, config} ->
        validate_rate_limit_config(changeset, config)

      {:pattern_match, config} ->
        validate_pattern_match_config(changeset, config)

      {:blocklist, config} ->
        validate_blocklist_config(changeset, config)

      {:payload_size, config} ->
        validate_payload_size_config(changeset, config)

      _other ->
        changeset
    end
  end

  defp validate_rate_limit_config(changeset, config) do
    cond do
      not is_integer(config["max_events"]) and not is_integer(config[:max_events]) ->
        add_error(changeset, :config, "rate_limit config requires max_events (integer)")

      not is_integer(config["window_seconds"]) and not is_integer(config[:window_seconds]) ->
        add_error(changeset, :config, "rate_limit config requires window_seconds (integer)")

      true ->
        changeset
    end
  end

  defp validate_pattern_match_config(changeset, config) do
    detection_rule_ids = config["detection_rule_ids"] || config[:detection_rule_ids]

    if is_list(detection_rule_ids) and detection_rule_ids != [] do
      changeset
    else
      add_error(
        changeset,
        :config,
        "pattern_match config requires detection_rule_ids (non-empty list)"
      )
    end
  end

  defp validate_blocklist_config(changeset, config) do
    values = config["values"] || config[:values]

    if is_list(values) and values != [] do
      changeset
    else
      add_error(changeset, :config, "blocklist config requires values (non-empty list)")
    end
  end

  defp validate_payload_size_config(changeset, config) do
    max_content = config["max_content_bytes"] || config[:max_content_bytes]
    max_payload = config["max_payload_bytes"] || config[:max_payload_bytes]

    if is_integer(max_content) or is_integer(max_payload) do
      changeset
    else
      add_error(
        changeset,
        :config,
        "payload_size config requires max_content_bytes or max_payload_bytes (integer)"
      )
    end
  end
end
