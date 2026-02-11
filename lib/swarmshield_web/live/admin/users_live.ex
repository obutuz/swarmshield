defmodule SwarmshieldWeb.Admin.UsersLive do
  @moduledoc """
  User management admin view.

  List workspace members with roles, change roles (with escalation prevention),
  remove users from workspace (with last-super_admin guard).
  Permission: settings:view / settings:update.
  """
  use SwarmshieldWeb, :live_view

  alias Swarmshield.Accounts
  alias SwarmshieldWeb.Hooks.AuthHooks

  # -------------------------------------------------------------------
  # Mount
  # -------------------------------------------------------------------

  @impl true
  def mount(_params, _session, socket) do
    workspace_id = socket.assigns.current_workspace.id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Swarmshield.PubSub, "workspace_users:#{workspace_id}")
    end

    {:ok, assign(socket, :page_title, "Manage Users")}
  end

  # -------------------------------------------------------------------
  # Handle params
  # -------------------------------------------------------------------

  @impl true
  def handle_params(_params, _uri, socket) do
    if AuthHooks.has_socket_permission?(socket, "settings:view") do
      workspace = socket.assigns.current_workspace
      {members, total} = Accounts.list_workspace_users(workspace.id)
      roles = Accounts.list_roles()

      {:noreply,
       socket
       |> assign(:page_title, "Manage Users")
       |> assign(:workspace, workspace)
       |> assign(:roles, roles)
       |> assign(:total_count, total)
       |> stream(:members, members, reset: true)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "You are not authorized to manage users.")
       |> redirect(to: ~p"/select-workspace")}
    end
  end

  # -------------------------------------------------------------------
  # Events
  # -------------------------------------------------------------------

  @impl true
  def handle_event("change_role", %{"uwr_id" => uwr_id, "role_id" => role_id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "settings:update") do
      do_change_role(socket, uwr_id, role_id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  def handle_event("remove_user", %{"user_id" => user_id}, socket) do
    if AuthHooks.has_socket_permission?(socket, "settings:update") do
      do_remove_user(socket, user_id)
    else
      {:noreply, put_flash(socket, :error, "Unauthorized")}
    end
  end

  # -------------------------------------------------------------------
  # PubSub
  # -------------------------------------------------------------------

  @impl true
  def handle_info({:user_role_changed, _workspace_id}, socket) do
    reload_members(socket)
  end

  def handle_info({:user_removed, _workspace_id}, socket) do
    reload_members(socket)
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp do_change_role(socket, uwr_id, role_id) do
    workspace = socket.assigns.workspace
    actor = socket.assigns.current_scope.user
    new_role = Accounts.get_role(role_id)

    # Find the target user from the UWR id
    target_uwr = find_member_by_uwr_id(workspace.id, uwr_id)

    cond do
      is_nil(new_role) ->
        {:noreply, put_flash(socket, :error, "Role not found.")}

      is_nil(target_uwr) ->
        {:noreply, put_flash(socket, :error, "User not found in workspace.")}

      true ->
        target_user = target_uwr.user

        case Accounts.change_user_workspace_role(actor, target_user, workspace, new_role) do
          {:ok, _uwr} ->
            broadcast_change(workspace.id, :user_role_changed)
            reload_members_with_flash(socket, "Role updated to #{new_role.name}.")

          {:error, reason} when is_binary(reason) ->
            {:noreply, put_flash(socket, :error, reason)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not update role.")}
        end
    end
  end

  defp do_remove_user(socket, user_id) do
    workspace = socket.assigns.workspace
    actor = socket.assigns.current_scope.user

    cond do
      user_id == actor.id ->
        {:noreply, put_flash(socket, :error, "You cannot remove yourself from the workspace.")}

      last_super_admin?(workspace.id, user_id) ->
        {:noreply,
         put_flash(socket, :error, "Cannot remove the last super_admin from the workspace.")}

      true ->
        target_user = Accounts.get_user!(user_id)
        Accounts.remove_user_from_workspace(target_user, workspace)
        broadcast_change(workspace.id, :user_removed)
        reload_members_with_flash(socket, "User removed from workspace.")
    end
  end

  defp find_member_by_uwr_id(workspace_id, uwr_id) do
    {members, _} = Accounts.list_workspace_users(workspace_id, page_size: 100)
    Enum.find(members, &(&1.id == uwr_id))
  end

  defp last_super_admin?(workspace_id, user_id) do
    count = Accounts.count_workspace_super_admins(workspace_id)
    uwr = find_member_by_user_id(workspace_id, user_id)
    count <= 1 and uwr != nil and uwr.role.name == "super_admin"
  end

  defp find_member_by_user_id(workspace_id, user_id) do
    {members, _} = Accounts.list_workspace_users(workspace_id, page_size: 100)
    Enum.find(members, &(&1.user_id == user_id))
  end

  defp reload_members(socket) do
    workspace = socket.assigns.workspace
    {members, total} = Accounts.list_workspace_users(workspace.id)

    {:noreply,
     socket
     |> assign(:total_count, total)
     |> stream(:members, members, reset: true)}
  end

  defp reload_members_with_flash(socket, message) do
    workspace = socket.assigns.workspace
    {members, total} = Accounts.list_workspace_users(workspace.id)

    {:noreply,
     socket
     |> assign(:total_count, total)
     |> stream(:members, members, reset: true)
     |> put_flash(:info, message)}
  end

  defp broadcast_change(workspace_id, event) do
    Phoenix.PubSub.broadcast_from(
      Swarmshield.PubSub,
      self(),
      "workspace_users:#{workspace_id}",
      {event, workspace_id}
    )
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp role_badge_class(role_name) do
    case role_name do
      "super_admin" -> "bg-purple-400/10 text-purple-400 border border-purple-400/30"
      "admin" -> "bg-blue-400/10 text-blue-400 border border-blue-400/30"
      "analyst" -> "bg-green-400/10 text-green-400 border border-green-400/30"
      "viewer" -> "bg-gray-400/10 text-gray-400 border border-gray-400/30"
      _ -> "bg-gray-400/10 text-gray-400 border border-gray-400/30"
    end
  end

  defp can_manage_user?(assigns, member) do
    AuthHooks.has_socket_permission?(assigns, "settings:update") and
      member.user_id != assigns.current_scope.user.id
  end

  defp format_datetime(nil), do: "—"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%b %d, %Y")
  end

  # -------------------------------------------------------------------
  # Render
  # -------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_workspace={@current_workspace}
      user_permissions={@user_permissions}
      active_nav={:admin_users}
    >
      <div class="space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-3xl font-bold text-gray-100">
              <.icon name="hero-users" class="size-8 inline-block mr-1 text-blue-400" /> Manage Users
            </h1>
            <p class="text-gray-400 mt-1">
              {@total_count} member(s) in this workspace
            </p>
          </div>
        </div>

        <%!-- Members table --%>
        <div class="bg-gray-800 border border-gray-700 rounded-lg overflow-hidden">
          <div class="overflow-x-auto">
            <table class="w-full min-w-[600px]">
              <thead>
                <tr class="border-b border-gray-700 text-left text-sm text-gray-400">
                  <th class="px-6 py-3 font-medium">Email</th>
                  <th class="px-6 py-3 font-medium">Role</th>
                  <th class="px-6 py-3 font-medium">Joined</th>
                  <th class="px-6 py-3 font-medium text-right">Actions</th>
                </tr>
              </thead>
              <tbody id="members" phx-update="stream">
                <tr
                  :for={{dom_id, member} <- @streams.members}
                  id={dom_id}
                  class="border-b border-gray-700/50 hover:bg-gray-700/30 transition-colors"
                >
                  <td class="px-6 py-4">
                    <div class="flex items-center gap-3">
                      <div class="w-8 h-8 rounded-full bg-gray-700 flex items-center justify-center text-sm font-medium text-gray-300">
                        {String.first(member.user.email) |> String.upcase()}
                      </div>
                      <div>
                        <p class="text-sm text-gray-100">{member.user.email}</p>
                        <p
                          :if={member.user_id == @current_scope.user.id}
                          class="text-xs text-blue-400"
                        >
                          You
                        </p>
                      </div>
                    </div>
                  </td>
                  <td class="px-6 py-4">
                    <span class={"inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium #{role_badge_class(member.role.name)}"}>
                      {member.role.name}
                    </span>
                  </td>
                  <td class="px-6 py-4 text-sm text-gray-400">
                    {format_datetime(member.inserted_at)}
                  </td>
                  <td class="px-6 py-4 text-right">
                    <div
                      :if={can_manage_user?(assigns, member)}
                      class="flex items-center justify-end gap-2"
                    >
                      <form phx-change="change_role" class="inline-block">
                        <input type="hidden" name="uwr_id" value={member.id} />
                        <select
                          name="role_id"
                          class="h-[34px] bg-gray-900 border border-gray-600 rounded text-gray-100 text-xs px-2 focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
                        >
                          <option
                            :for={role <- @roles}
                            value={role.id}
                            selected={role.id == member.role_id}
                          >
                            {role.name}
                          </option>
                        </select>
                      </form>
                      <button
                        type="button"
                        phx-click="remove_user"
                        phx-value-user_id={member.user_id}
                        data-confirm={"Remove #{member.user.email} from this workspace? They will lose all access."}
                        class="inline-flex items-center gap-1 px-3 py-1.5 rounded border border-red-400/30 text-red-400 hover:bg-red-400/10 text-xs font-medium transition-colors"
                      >
                        <.icon name="hero-x-mark" class="size-3.5" /> Remove
                      </button>
                    </div>
                    <span
                      :if={!can_manage_user?(assigns, member)}
                      class="text-xs text-gray-500"
                    >
                      —
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <%!-- Empty state --%>
          <div
            :if={@total_count == 0}
            class="flex flex-col items-center justify-center py-16 text-gray-500"
          >
            <.icon name="hero-users" class="size-12 mb-3 text-gray-600" />
            <p class="text-sm">No users in this workspace</p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
