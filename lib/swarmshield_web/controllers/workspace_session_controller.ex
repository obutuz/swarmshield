defmodule SwarmshieldWeb.WorkspaceSessionController do
  @moduledoc """
  Sets the active workspace in the Plug session.

  LiveViews cannot set Plug session values directly, so workspace selection
  flows (WorkspaceSelectorLive, OnboardingLive) POST here via phx-trigger-action
  to persist the chosen workspace_id into the session before redirecting.
  """
  use SwarmshieldWeb, :controller

  alias Swarmshield.Accounts
  alias Swarmshield.Accounts.{User, Workspace}

  def create(conn, %{"workspace_id" => workspace_id}) do
    user = conn.assigns.current_scope.user
    redirect_to = get_session(conn, :user_return_to) || "/dashboard"

    with {:ok, _uuid} <- Ecto.UUID.cast(workspace_id),
         %Workspace{status: :active} = workspace <- Accounts.get_workspace(workspace_id),
         :ok <- verify_access(user, workspace) do
      conn
      |> delete_session(:user_return_to)
      |> put_session(:current_workspace_id, workspace.id)
      |> redirect(to: redirect_to)
    else
      :error ->
        conn
        |> put_flash(:error, "Invalid workspace.")
        |> redirect(to: "/select-workspace")

      nil ->
        conn
        |> put_flash(:error, "Workspace not found.")
        |> redirect(to: "/select-workspace")

      %Workspace{status: status} when status in [:suspended, :archived] ->
        conn
        |> put_flash(:error, "This workspace is #{status}.")
        |> redirect(to: "/select-workspace")

      {:error, :not_member} ->
        conn
        |> put_flash(:error, "You are not a member of this workspace.")
        |> redirect(to: "/select-workspace")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Invalid workspace.")
    |> redirect(to: "/select-workspace")
  end

  # System owners can access any workspace without membership
  defp verify_access(%User{is_system_owner: true}, %Workspace{}), do: :ok

  defp verify_access(%User{} = user, %Workspace{} = workspace) do
    case Accounts.get_user_workspace_role(user, workspace) do
      nil -> {:error, :not_member}
      _uwr -> :ok
    end
  end
end
