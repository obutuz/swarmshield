defmodule SwarmshieldWeb.ChangesetJSON do
  @doc """
  Renders changeset errors as a JSON map.
  """
  def error(%{changeset: changeset}) do
    %{errors: Ecto.Changeset.traverse_errors(changeset, &translate_error/1)}
  end

  defp translate_error({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      interpolate_key(key, opts)
    end)
  end

  defp interpolate_key(key, opts) do
    atom_key = String.to_existing_atom(key)
    opts |> Keyword.get(atom_key, key) |> to_string()
  rescue
    ArgumentError -> key
  end
end
