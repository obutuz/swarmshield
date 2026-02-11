defmodule Swarmshield.UnauthorizedError do
  @moduledoc """
  Raised when a user attempts an action they are not authorized to perform.
  """

  defexception [:message, :permission]

  @impl true
  def exception(opts) do
    permission = Keyword.get(opts, :permission, "unknown")

    message =
      Keyword.get(opts, :message, "Not authorized to perform action: #{permission}")

    %__MODULE__{message: message, permission: permission}
  end
end
