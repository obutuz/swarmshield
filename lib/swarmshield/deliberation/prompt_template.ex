defmodule Swarmshield.Deliberation.PromptTemplate do
  @moduledoc """
  PromptTemplate stores variable-interpolated prompt templates used by
  agent definitions during deliberation.

  Templates use `{{variable}}` syntax for dynamic content injection.
  Variable extraction is automatic on insert/update. Template interpolation
  uses safe String.replace/3 only - NEVER Code.eval_string or EEx.eval_string.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_template_bytes 102_400

  schema "prompt_templates" do
    field :name, :string
    field :description, :string
    field :template, :string
    field :variables, {:array, :string}, default: []
    field :category, :string
    field :version, :integer, default: 1
    field :enabled, :boolean, default: true

    belongs_to :workspace, Swarmshield.Accounts.Workspace

    timestamps(type: :utc_datetime)
  end

  @doc """
  User-facing changeset for creating/updating prompt templates.
  Auto-extracts variables from template on change.
  """
  def changeset(template, attrs) do
    template
    |> cast(attrs, [:name, :description, :template, :category, :version, :enabled])
    |> validate_required([:name, :template])
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_length(:template, max: @max_template_bytes, count: :bytes)
    |> validate_length(:category, max: 255)
    |> auto_extract_variables()
    |> auto_increment_version()
    |> foreign_key_constraint(:workspace_id)
  end

  @doc """
  Extracts unique variable names from a template string.
  Variables are identified by the `{{variable_name}}` pattern.

  ## Examples

      iex> extract_variables("Hello {{name}}, your {{role}} is ready")
      ["name", "role"]

      iex> extract_variables("No variables here")
      []

      iex> extract_variables("Duplicate {{name}} and {{name}}")
      ["name"]
  """
  def extract_variables(template) when is_binary(template) do
    ~r/\{\{(\w+)\}\}/
    |> Regex.scan(template, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  def extract_variables(_), do: []

  @doc """
  Renders a template by replacing `{{variable}}` placeholders with values.
  Uses safe String.replace/3 - NEVER Code.eval_string.
  """
  def render(template, variables) when is_binary(template) and is_map(variables) do
    Enum.reduce(variables, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp auto_extract_variables(changeset) do
    case get_change(changeset, :template) do
      nil -> changeset
      template -> put_change(changeset, :variables, extract_variables(template))
    end
  end

  defp auto_increment_version(changeset) do
    if changeset.data.id && get_change(changeset, :template) do
      current_version = get_field(changeset, :version) || 1
      put_change(changeset, :version, current_version + 1)
    else
      changeset
    end
  end
end
