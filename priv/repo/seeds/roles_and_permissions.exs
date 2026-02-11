# Seeds default roles and permissions for SwarmShield RBAC.
# Idempotent - safe to run multiple times.
#
# Usage:
#   mix run priv/repo/seeds/roles_and_permissions.exs

import Ecto.Query

alias Swarmshield.Accounts.{Permission, Role, RolePermission}
alias Swarmshield.Repo

# --- Permissions ---

permissions = [
  %{resource: "dashboard", action: "view", description: "View dashboard"},
  %{resource: "dashboard", action: "export", description: "Export dashboard data"},
  %{resource: "events", action: "view", description: "View events"},
  %{resource: "events", action: "export", description: "Export events"},
  %{resource: "agents", action: "view", description: "View agents"},
  %{resource: "agents", action: "create", description: "Create agents"},
  %{resource: "agents", action: "update", description: "Update agents"},
  %{resource: "agents", action: "delete", description: "Delete agents"},
  %{resource: "workflows", action: "view", description: "View workflows"},
  %{resource: "workflows", action: "create", description: "Create workflows"},
  %{resource: "workflows", action: "update", description: "Update workflows"},
  %{resource: "workflows", action: "delete", description: "Delete workflows"},
  %{resource: "policies", action: "view", description: "View policies"},
  %{resource: "policies", action: "create", description: "Create policies"},
  %{resource: "policies", action: "update", description: "Update policies"},
  %{resource: "policies", action: "delete", description: "Delete policies"},
  %{resource: "deliberations", action: "view", description: "View deliberations"},
  %{resource: "deliberations", action: "trigger", description: "Trigger deliberations"},
  %{resource: "deliberations", action: "export", description: "Export deliberations"},
  %{resource: "audit", action: "view", description: "View audit log"},
  %{resource: "audit", action: "export", description: "Export audit log"},
  %{resource: "settings", action: "view", description: "View settings"},
  %{resource: "settings", action: "update", description: "Update settings"},
  %{resource: "admin", action: "access", description: "Access admin panel"}
]

now = DateTime.utc_now(:second)

permission_records =
  Enum.map(permissions, fn attrs ->
    Map.merge(attrs, %{inserted_at: now, updated_at: now})
  end)

Repo.insert_all(Permission, permission_records,
  on_conflict: :nothing,
  conflict_target: [:resource, :action]
)

# Load all permissions from DB for role assignment
all_permissions =
  Repo.all(from(p in Permission, select: {fragment("? || ':' || ?", p.resource, p.action), p.id}))
  |> Map.new()

IO.puts("[Seeds] #{map_size(all_permissions)} permissions available")

# --- Roles ---

roles = [
  %{name: "super_admin", description: "Full system access", is_system: true},
  %{
    name: "admin",
    description: "Administrative access (all except system settings)",
    is_system: true
  },
  %{name: "analyst", description: "View, trigger, and export access", is_system: true},
  %{name: "viewer", description: "Read-only access", is_system: true}
]

role_records =
  Enum.map(roles, fn attrs ->
    Map.merge(attrs, %{inserted_at: now, updated_at: now})
  end)

Repo.insert_all(Role, role_records,
  on_conflict: :nothing,
  conflict_target: [:name]
)

# Load all roles from DB
all_roles =
  Repo.all(from(r in Role, select: {r.name, r.id}))
  |> Map.new()

IO.puts("[Seeds] #{map_size(all_roles)} roles available")

# --- Role-Permission assignments ---

# super_admin: ALL permissions
super_admin_perms = Map.keys(all_permissions)

# admin: All except settings:update
admin_perms =
  all_permissions
  |> Map.keys()
  |> Enum.reject(&(&1 == "settings:update"))

# analyst: view + trigger + export permissions
analyst_perms =
  all_permissions
  |> Map.keys()
  |> Enum.filter(fn key ->
    String.ends_with?(key, ":view") or
      String.ends_with?(key, ":trigger") or
      String.ends_with?(key, ":export")
  end)

# viewer: view-only permissions
viewer_perms =
  all_permissions
  |> Map.keys()
  |> Enum.filter(&String.ends_with?(&1, ":view"))

role_permission_assignments = [
  {"super_admin", super_admin_perms},
  {"admin", admin_perms},
  {"analyst", analyst_perms},
  {"viewer", viewer_perms}
]

Enum.each(role_permission_assignments, fn {role_name, perm_keys} ->
  role_id = Map.fetch!(all_roles, role_name)

  records =
    Enum.map(perm_keys, fn perm_key ->
      permission_id = Map.fetch!(all_permissions, perm_key)
      %{role_id: role_id, permission_id: permission_id, inserted_at: now, updated_at: now}
    end)

  {count, _} =
    Repo.insert_all(RolePermission, records,
      on_conflict: :nothing,
      conflict_target: [:role_id, :permission_id]
    )

  IO.puts("[Seeds] #{role_name}: #{count} new permissions assigned (#{length(perm_keys)} total)")
end)

IO.puts("[Seeds] Roles and permissions seeded successfully")
