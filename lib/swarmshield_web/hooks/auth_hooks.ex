defmodule SwarmshieldWeb.Hooks.AuthHooks do
  @moduledoc """
  LiveView on_mount hooks for workspace-scoped authentication and authorization.

  Hooks (used in order via live_session on_mount):
  - `:ensure_authenticated` - Verifies user is authenticated, redirects to login if not
  - `:load_workspace` - Loads workspace from session, assigns workspace + role + permissions
  - `{:require_permission, key}` - Checks user has a specific permission in the workspace

  ## Usage in router.ex

      live_session :workspace_authenticated,
        on_mount: [
          {SwarmshieldWeb.Hooks.AuthHooks, :ensure_authenticated},
          {SwarmshieldWeb.Hooks.AuthHooks, :load_workspace}
        ] do
        live "/dashboard", DashboardLive
      end

  ## Socket assigns after hooks

  - `:current_scope` - `%Scope{user: %User{}}` (from :ensure_authenticated)
  - `:current_workspace` - `%Workspace{}` (from :load_workspace)
  - `:current_role` - `%Role{}` (from :load_workspace)
  - `:user_permissions` - `MapSet` of permission keys or `:all` (from :load_workspace)
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3, assign_new: 3]

  use SwarmshieldWeb, :verified_routes

  alias Swarmshield.Accounts
  alias Swarmshield.Accounts.{Scope, User}
  alias Swarmshield.Authorization

  # Route paths used by hooks. /select-workspace is defined in AUTH-015.
  # Using module attribute to centralize the path until route is wired.
  @workspace_selector_path "/select-workspace"

  @doc """
  LiveView on_mount callback for workspace-scoped auth hooks.

  ## Hook types

  - `:ensure_authenticated` - Verifies user is authenticated, redirects to login if not.
    Assigns `:current_scope` to socket via `assign_new` (idempotent with UserAuth).

  - `:load_workspace` - Loads workspace from session, validates membership, assigns context.
    Must be called AFTER `:ensure_authenticated`.
    Assigns `:current_workspace`, `:current_role`, `:user_permissions`.

  - `{:require_permission, key}` - Checks user has a specific permission.
    Must be called AFTER `:load_workspace`.
  """
  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    case socket.assigns.current_scope do
      %Scope{user: %User{}} ->
        {:cont, socket}

      _ ->
        socket =
          socket
          |> put_flash(:error, "You must log in to access this page.")
          |> redirect(to: ~p"/users/log-in")

        {:halt, socket}
    end
  end

  def on_mount(:load_workspace, _params, session, socket) do
    user = socket.assigns.current_scope.user
    workspace_id = session["current_workspace_id"]

    case load_workspace_context(user, workspace_id) do
      {:ok, workspace, role, permissions} ->
        socket =
          socket
          |> assign(:current_workspace, workspace)
          |> assign(:current_role, role)
          |> assign(:user_permissions, permissions)

        {:cont, socket}

      {:error, :no_workspace_in_session} ->
        {:halt, redirect(socket, to: @workspace_selector_path)}

      {:error, :invalid_workspace_id} ->
        {:halt, redirect(socket, to: @workspace_selector_path)}

      {:error, :workspace_not_found} ->
        {:halt, redirect(socket, to: @workspace_selector_path)}

      {:error, :workspace_suspended} ->
        socket =
          socket
          |> put_flash(
            :error,
            "This workspace has been suspended. Please contact your administrator."
          )
          |> redirect(to: @workspace_selector_path)

        {:halt, socket}

      {:error, :workspace_archived} ->
        socket =
          socket
          |> put_flash(:error, "This workspace has been archived.")
          |> redirect(to: @workspace_selector_path)

        {:halt, socket}

      {:error, :not_member} ->
        socket =
          socket
          |> put_flash(:error, "You are not a member of this workspace.")
          |> redirect(to: @workspace_selector_path)

        {:halt, socket}
    end
  end

  def on_mount({:require_permission, permission_key}, _params, _session, socket) do
    if has_socket_permission?(socket, permission_key) do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You are not authorized to access this page.")
        |> redirect(to: ~p"/")

      {:halt, socket}
    end
  end

  # --- Public helpers for LiveViews ---

  @doc """
  Checks if the socket has a specific permission assigned.
  Used in handle_event callbacks without re-querying the database or ETS.

  ## Example

      def handle_event("delete_agent", _params, socket) do
        if AuthHooks.has_socket_permission?(socket, "agents:delete") do
          # proceed with deletion
        else
          {:noreply, put_flash(socket, :error, "Not authorized")}
        end
      end
  """
  def has_socket_permission?(%{assigns: assigns}, permission_key) do
    check_permission(assigns, permission_key)
  end

  # --- Private helpers ---

  defp mount_current_scope(socket, session) do
    assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  defp load_workspace_context(_user, nil), do: {:error, :no_workspace_in_session}
  defp load_workspace_context(_user, ""), do: {:error, :no_workspace_in_session}

  defp load_workspace_context(user, workspace_id) do
    with :ok <- validate_binary_id(workspace_id),
         {:ok, workspace} <- fetch_workspace(workspace_id),
         :ok <- check_workspace_status(workspace),
         {:ok, uwr} <- fetch_membership(user, workspace) do
      permissions = Authorization.get_user_permissions(user.id, workspace.id)
      {:ok, workspace, uwr.role, permissions}
    end
  end

  defp validate_binary_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> :ok
      :error -> {:error, :invalid_workspace_id}
    end
  end

  defp validate_binary_id(_), do: {:error, :invalid_workspace_id}

  defp fetch_workspace(workspace_id) do
    case Accounts.get_workspace(workspace_id) do
      nil -> {:error, :workspace_not_found}
      workspace -> {:ok, workspace}
    end
  end

  defp check_workspace_status(%{status: :active}), do: :ok
  defp check_workspace_status(%{status: :suspended}), do: {:error, :workspace_suspended}
  defp check_workspace_status(%{status: :archived}), do: {:error, :workspace_archived}

  defp fetch_membership(user, workspace) do
    case Accounts.get_user_workspace_role(user, workspace) do
      nil -> {:error, :not_member}
      uwr -> {:ok, uwr}
    end
  end

  defp check_permission(%{user_permissions: :all}, _permission_key), do: true

  defp check_permission(%{user_permissions: %MapSet{} = perms}, permission_key),
    do: MapSet.member?(perms, permission_key)

  defp check_permission(_, _), do: false
end
