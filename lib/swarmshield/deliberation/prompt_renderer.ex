defmodule Swarmshield.Deliberation.PromptRenderer do
  @moduledoc """
  Pure function module for rendering prompt templates with variable interpolation.

  Provides safe, deterministic template rendering with proper error handling.
  All functions are side-effect free (no database calls, no I/O).

  Templates use `{{variable_name}}` syntax. Variable names must consist of
  word characters (letters, digits, underscores).

  ## Security

  Rendering uses only `String.replace/3` - NEVER `Code.eval_string/1` or
  `EEx.eval_string/2`. Variable values are inserted literally with no
  recursive expansion.

  ## Relationship to PromptTemplate

  `Swarmshield.Deliberation.PromptTemplate` is the Ecto schema that persists
  templates. This module provides the rendering engine with proper tuple-based
  error handling suitable for pipeline composition.
  """

  @variable_pattern ~r/\{\{(\w+)\}\}/

  @doc """
  Renders a template string by replacing `{{variable}}` placeholders with
  values from the provided map.

  Returns `{:ok, rendered_string}` on success, or
  `{:error, :missing_variables, [names]}` when required variables are absent.

  Variable values are inserted literally - a value containing `{{other}}`
  will NOT be recursively expanded.

  ## Examples

      iex> render("Hello {{name}}", %{"name" => "World"})
      {:ok, "Hello World"}

      iex> render("Hello {{name}}", %{})
      {:error, :missing_variables, ["name"]}

      iex> render("", %{"unused" => "value"})
      {:ok, ""}
  """
  @spec render(binary(), map()) :: {:ok, binary()} | {:error, :missing_variables, [String.t()]}
  def render("", _variables), do: {:ok, ""}

  def render(template, variables) when is_binary(template) and is_map(variables) do
    required = extract_variables(template)
    provided_keys = variable_keys(variables)

    case required -- provided_keys do
      [] ->
        rendered = replace_variables(template, variables)
        {:ok, rendered}

      missing ->
        {:error, :missing_variables, Enum.sort(missing)}
    end
  end

  @doc """
  Extracts unique variable names from a template string, returned sorted.

  Variables are identified by the `{{variable_name}}` pattern where
  `variable_name` consists of one or more word characters (`\\w+`).
  Empty braces `{{}}` are treated as literal text and ignored.

  ## Examples

      iex> extract_variables("Hello {{name}}, your {{role}} is ready")
      ["name", "role"]

      iex> extract_variables("No variables here")
      []

      iex> extract_variables("Duplicate {{name}} and {{name}}")
      ["name"]
  """
  @spec extract_variables(binary()) :: [String.t()]
  def extract_variables(template) when is_binary(template) do
    @variable_pattern
    |> Regex.scan(template, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Validates that a template's required variables are all present in the
  available variables list.

  Returns `:ok` when all required variables are available, or
  `{:error, :missing_variables, missing_list}` with sorted missing names.

  ## Examples

      iex> validate_template("Hello {{name}}", ["name", "role"])
      :ok

      iex> validate_template("{{a}} and {{b}}", ["a"])
      {:error, :missing_variables, ["b"]}
  """
  @spec validate_template(binary(), [String.t()]) ::
          :ok | {:error, :missing_variables, [String.t()]}
  def validate_template(template, available_variables)
      when is_binary(template) and is_list(available_variables) do
    required = extract_variables(template)

    case required -- available_variables do
      [] -> :ok
      missing -> {:error, :missing_variables, Enum.sort(missing)}
    end
  end

  # -- Private helpers --------------------------------------------------------

  defp replace_variables(template, variables) do
    Enum.reduce(variables, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end

  defp variable_keys(variables) do
    variables
    |> Map.keys()
    |> Enum.map(&to_string/1)
  end
end
