defmodule Swarmshield.Policies.DetectionRule do
  @moduledoc """
  DetectionRule defines a pattern matcher (regex or keyword list) used by
  pattern_match policy rules.

  Separated from PolicyRule for reusability - multiple policy rules can
  reference the same detection patterns. Supports regex, keyword, and
  semantic detection types.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @detection_types [:regex, :keyword, :semantic]
  @severities [:low, :medium, :high, :critical]

  @max_pattern_length 10_000
  @max_keywords_count 1_000
  @max_keyword_length 500

  schema "detection_rules" do
    field :name, :string
    field :description, :string
    field :detection_type, Ecto.Enum, values: @detection_types
    field :pattern, :string
    field :keywords, {:array, :string}, default: []
    field :severity, Ecto.Enum, values: @severities, default: :medium
    field :enabled, :boolean, default: true
    field :category, :string

    belongs_to :workspace, Swarmshield.Accounts.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc """
  User-facing changeset for creating/updating detection rules.
  workspace_id is set server-side.
  """
  def changeset(rule, attrs) do
    rule
    |> cast(attrs, [
      :name,
      :description,
      :detection_type,
      :pattern,
      :keywords,
      :severity,
      :enabled,
      :category
    ])
    |> validate_required([:name, :detection_type])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_length(:category, max: 255)
    |> validate_length(:pattern, max: @max_pattern_length)
    |> validate_type_specific_fields()
    |> validate_regex_compilation()
    |> validate_keywords_limits()
    |> foreign_key_constraint(:workspace_id)
    |> unique_constraint([:workspace_id, :name])
  end

  defp validate_type_specific_fields(changeset) do
    detection_type = get_field(changeset, :detection_type)
    pattern = get_field(changeset, :pattern)
    keywords = get_field(changeset, :keywords)

    case detection_type do
      :regex ->
        if is_nil(pattern) or pattern == "" do
          add_error(changeset, :pattern, "is required for regex detection type")
        else
          changeset
        end

      :keyword ->
        if is_nil(keywords) or keywords == [] do
          add_error(changeset, :keywords, "must be non-empty for keyword detection type")
        else
          changeset
        end

      :semantic ->
        changeset

      _other ->
        changeset
    end
  end

  defp validate_regex_compilation(changeset) do
    detection_type = get_field(changeset, :detection_type)
    pattern = get_change(changeset, :pattern)

    case {detection_type, pattern} do
      {:regex, pattern} when is_binary(pattern) and pattern != "" ->
        case Regex.compile(pattern) do
          {:ok, _regex} ->
            validate_regex_safety(changeset, pattern)

          {:error, {reason, _pos}} ->
            add_error(changeset, :pattern, "invalid regex: #{reason}")
        end

      _other ->
        changeset
    end
  end

  defp validate_regex_safety(changeset, pattern) do
    task =
      Task.async(fn ->
        regex = Regex.compile!(pattern)
        # Test with non-matching input to trigger catastrophic backtracking.
        # ReDoS only occurs when the engine must explore all possible paths
        # before concluding there is no match. A matching input resolves instantly.
        pathological_input = String.duplicate("a", 1000) <> "!"
        Regex.match?(regex, pathological_input)
      end)

    case Task.yield(task, 100) || Task.shutdown(task) do
      {:ok, _result} ->
        changeset

      nil ->
        add_error(
          changeset,
          :pattern,
          "regex pattern is potentially unsafe (catastrophic backtracking detected)"
        )
    end
  end

  defp validate_keywords_limits(changeset) do
    keywords = get_field(changeset, :keywords) || []

    cond do
      length(keywords) > @max_keywords_count ->
        add_error(changeset, :keywords, "cannot exceed #{@max_keywords_count} keywords")

      Enum.any?(keywords, fn kw -> is_binary(kw) and byte_size(kw) > @max_keyword_length end) ->
        add_error(
          changeset,
          :keywords,
          "each keyword must be at most #{@max_keyword_length} characters"
        )

      true ->
        changeset
    end
  end
end
