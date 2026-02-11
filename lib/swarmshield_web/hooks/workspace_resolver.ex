defmodule SwarmshieldWeb.Hooks.WorkspaceResolver do
  @moduledoc """
  Resolves workspace for authenticated users after login and validates
  workspace session state on subsequent requests.

  ## Post-login resolution (called from UserAuth.log_in_user/3)

  - 0 workspaces → redirect to /onboarding
  - 1 workspace → store workspace_id in session, redirect to /dashboard
  - 2+ workspaces → redirect to /select-workspace

  ## Session validation (Plug interface)

  Validates that the workspace_id stored in the session is still valid
  (exists, active, user is still a member). Clears stale session data.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias Swarmshield.Accounts
  alias Swarmshield.Accounts.User

  # Forward references: routes wired in AUTH-015
  @dashboard_path "/dashboard"
  @onboarding_path "/onboarding"
  @workspace_selector_path "/select-workspace"

  # --- Post-login resolution ---

  @doc """
  Resolves the user's workspace after login and redirects accordingly.

  Called from `UserAuth.log_in_user/3` when there is no `user_return_to` path.

  - 0 workspaces → redirect to /onboarding
  - 1 workspace → sets `current_workspace_id` in session, redirect to /dashboard
  - 2+ workspaces → redirect to /select-workspace
  """
  def resolve_and_redirect(conn, %User{} = user) do
    {workspaces, total_count} = Accounts.list_user_workspaces(user, page_size: 2)

    case {workspaces, total_count} do
      {_, 0} ->
        redirect(conn, to: @onboarding_path)

      {[single], 1} ->
        conn
        |> put_session(:current_workspace_id, single.workspace_id)
        |> redirect(to: @dashboard_path)

      {_, _count} ->
        redirect(conn, to: @workspace_selector_path)
    end
  end

  # --- Plug interface for session validation ---

  @doc """
  Plug that validates the workspace stored in session for authenticated users.

  If the session workspace_id is stale (workspace deleted, suspended, archived,
  or user removed from workspace), clears it and redirects to workspace selector.

  Use in router pipelines for non-LiveView controller routes.
  For LiveViews, the `:load_workspace` on_mount hook (AUTH-011) handles this.
  """
  def init(opts), do: opts

  def call(conn, _opts) do
    case {conn.assigns[:current_scope], get_session(conn, :current_workspace_id)} do
      {%{user: %User{} = user}, workspace_id} when is_binary(workspace_id) ->
        validate_session_workspace(conn, user, workspace_id)

      _ ->
        conn
    end
  end

  defp validate_session_workspace(conn, user, workspace_id) do
    case Accounts.get_workspace(workspace_id) do
      %{status: :active} = workspace ->
        validate_membership(conn, user, workspace)

      %{status: :suspended} ->
        conn
        |> delete_session(:current_workspace_id)
        |> put_flash(:error, "This workspace has been suspended.")
        |> redirect(to: @workspace_selector_path)
        |> halt()

      %{status: :archived} ->
        conn
        |> delete_session(:current_workspace_id)
        |> put_flash(:error, "This workspace has been archived.")
        |> redirect(to: @workspace_selector_path)
        |> halt()

      nil ->
        conn
        |> delete_session(:current_workspace_id)
        |> redirect(to: @workspace_selector_path)
        |> halt()
    end
  end

  defp validate_membership(conn, user, workspace) do
    case Accounts.get_user_workspace_role(user, workspace) do
      nil ->
        conn
        |> delete_session(:current_workspace_id)
        |> put_flash(:error, "You are no longer a member of this workspace.")
        |> redirect(to: @workspace_selector_path)
        |> halt()

      _uwr ->
        conn
    end
  end
end
