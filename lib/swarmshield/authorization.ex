defmodule Swarmshield.Authorization do
  @moduledoc """
  Authorization module with ETS-cached permission lookups.

  All permission checks resolve from the database via context functions.
  Zero hardcoded permission checks or role name comparisons.

  Architecture:
  - Pure check functions read from ETS cache first
  - On cache miss, loads from database and caches for subsequent calls
  - PubSub-driven invalidation on role/permission changes
  - Workspace status checked on cache load (suspended = no permissions)
  """

  import Ecto.Query, warn: false

  alias Swarmshield.Accounts.{Permission, RolePermission, UserWorkspaceRole, Workspace}
  alias Swarmshield.Authorization.AuthCache
  alias Swarmshield.Repo

  @doc """
  Checks if a user has a specific permission in a workspace.
  Reads from ETS cache first, falls back to database on cache miss.

  Returns `false` for nil user, nil workspace, or suspended workspace.
  """
  def has_permission?(nil, _workspace, _permission_key), do: false
  def has_permission?(_user, nil, _permission_key), do: false

  def has_permission?(%{id: user_id}, %{id: workspace_id}, permission_key)
      when is_binary(permission_key) do
    permissions = get_or_load_permissions(user_id, workspace_id)
    check_permission(permissions, permission_key)
  end

  def has_permission?(_user, _workspace, _permission_key), do: false

  @doc """
  Checks if a user has a specific role in a workspace.
  Queries the database (role names are not cached in the permission set).
  """
  def has_role?(nil, _workspace, _role_name), do: false
  def has_role?(_user, nil, _role_name), do: false

  def has_role?(%{id: user_id}, %{id: workspace_id}, role_name) when is_binary(role_name) do
    query =
      from(uwr in UserWorkspaceRole,
        join: r in assoc(uwr, :role),
        where: uwr.user_id == ^user_id and uwr.workspace_id == ^workspace_id,
        where: r.name == ^role_name,
        select: true
      )

    Repo.exists?(query)
  end

  def has_role?(_user, _workspace, _role_name), do: false

  @doc """
  Checks if a user has ANY of the given permissions in a workspace.
  Returns `true` if at least one permission matches.
  """
  def has_any_permission?(nil, _workspace, _permission_keys), do: false
  def has_any_permission?(_user, nil, _permission_keys), do: false
  def has_any_permission?(_user, _workspace, []), do: false

  def has_any_permission?(%{id: user_id}, %{id: workspace_id}, permission_keys)
      when is_list(permission_keys) do
    permissions = get_or_load_permissions(user_id, workspace_id)
    Enum.any?(permission_keys, &check_permission(permissions, &1))
  end

  def has_any_permission?(_user, _workspace, _permission_keys), do: false

  @doc """
  Authorizes a user for a permission. Returns `:ok` or raises `Swarmshield.UnauthorizedError`.
  """
  def authorize!(nil, _workspace, permission_key) do
    raise Swarmshield.UnauthorizedError, permission: permission_key
  end

  def authorize!(_user, nil, permission_key) do
    raise Swarmshield.UnauthorizedError, permission: permission_key
  end

  def authorize!(%{id: _} = user, %{id: _} = workspace, permission_key) do
    if has_permission?(user, workspace, permission_key) do
      :ok
    else
      raise Swarmshield.UnauthorizedError, permission: permission_key
    end
  end

  @doc """
  Returns the cached permission set for a user in a workspace.
  Returns a `MapSet` of permission keys, `:all` for super admin, or an empty `MapSet`.

  Used by on_mount hooks to assign permissions to socket for handle_event checks.
  """
  def get_user_permissions(user_id, workspace_id) do
    get_or_load_permissions(user_id, workspace_id)
  end

  @doc """
  Invalidates cached permissions for a specific user+workspace pair.
  Call this when a user's role assignment changes.
  """
  def invalidate_user_permissions(user_id, workspace_id) do
    AuthCache.invalidate(user_id, workspace_id)
  end

  @doc """
  Invalidates ALL cached permissions for a workspace.
  Call this when role-permission mappings change (affects all users).
  """
  def invalidate_workspace_permissions(workspace_id) do
    AuthCache.invalidate_workspace(workspace_id)
  end

  # Private helpers

  defp get_or_load_permissions(user_id, workspace_id) do
    case AuthCache.get_permissions(user_id, workspace_id) do
      {:ok, permissions} ->
        permissions

      :miss ->
        permissions = load_permissions_from_db(user_id, workspace_id)
        AuthCache.put_permissions(user_id, workspace_id, permissions)
        permissions
    end
  end

  defp load_permissions_from_db(user_id, workspace_id) do
    # Check workspace status first - suspended workspaces grant no permissions
    case Repo.get(Workspace, workspace_id) do
      %Workspace{status: status} when status != :active ->
        MapSet.new()

      %Workspace{} ->
        load_user_permissions(user_id, workspace_id)

      nil ->
        MapSet.new()
    end
  end

  defp load_user_permissions(user_id, workspace_id) do
    # Load the user's permissions via their role assignment
    permission_keys =
      from(uwr in UserWorkspaceRole,
        join: rp in RolePermission,
        on: rp.role_id == uwr.role_id,
        join: p in Permission,
        on: p.id == rp.permission_id,
        where: uwr.user_id == ^user_id and uwr.workspace_id == ^workspace_id,
        select: fragment("? || ':' || ?", p.resource, p.action)
      )
      |> Repo.all()

    user_perms = MapSet.new(permission_keys)

    # Check if user has ALL permissions (e.g., super_admin role)
    # This is database-driven: if role has every permission, cache as :all
    total_permission_count = Repo.aggregate(Permission, :count)

    if total_permission_count > 0 and MapSet.size(user_perms) >= total_permission_count do
      :all
    else
      user_perms
    end
  end

  defp check_permission(:all, _permission_key), do: true

  defp check_permission(%MapSet{} = perms, permission_key),
    do: MapSet.member?(perms, permission_key)

  defp check_permission(_, _), do: false
end
