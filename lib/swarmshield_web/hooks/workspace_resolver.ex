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

  Called from `UserAuth.log_in_user/3` after session creation.

  - 0 workspaces → redirect to /onboarding (ignores redirect_to)
  - 1 workspace → sets `current_workspace_id` in session, redirect to redirect_to or /dashboard
  - 2+ workspaces → stores redirect_to in session for post-selection, redirect to /select-workspace

  The optional `redirect_to` parameter preserves the user's intended destination
  (e.g. when they were redirected to login from a protected page).
  """
  def resolve_and_redirect(conn, %User{} = user, redirect_to \\ nil) do
    {workspaces, total_count} = Accounts.list_user_workspaces(user, page_size: 2)
    destination = redirect_to || @dashboard_path

    case {user, workspaces, total_count} do
      # System owner with no memberships → workspace selector (they can access any workspace)
      {%User{is_system_owner: true}, _, 0} ->
        conn
        |> maybe_store_return_to(redirect_to)
        |> redirect(to: @workspace_selector_path)

      # Regular user with no workspaces → onboarding
      {_, _, 0} ->
        conn
        |> delete_session(:user_return_to)
        |> redirect(to: @onboarding_path)

      # Single workspace → auto-select and redirect to destination
      {_, [single], 1} ->
        conn
        |> put_session(:current_workspace_id, single.workspace_id)
        |> delete_session(:user_return_to)
        |> redirect(to: destination)

      # Multiple workspaces → workspace selector
      {_, _, _count} ->
        conn
        |> maybe_store_return_to(redirect_to)
        |> redirect(to: @workspace_selector_path)
    end
  end

  defp maybe_store_return_to(conn, nil), do: delete_session(conn, :user_return_to)
  defp maybe_store_return_to(conn, path), do: put_session(conn, :user_return_to, path)

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

  # System owners bypass membership check
  defp validate_membership(conn, %User{is_system_owner: true}, _workspace), do: conn

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
