defmodule SwarmshieldWeb.Layouts do
  @moduledoc """
  Layout components for SwarmShield.

  Provides `app/1` (header + sidebar layout for workspace-authenticated views)
  and supporting components like `flash_group/1` and `theme_toggle/1`.

  Structure (adapted from pact_africa dashboard pattern):
  - Desktop: sticky header (h-16) → sidebar (w-64) + main content
  - Mobile: sticky header (h-14) → main content → bottom nav (h-16)
  - Mobile sidebar: overlay + slide-in from left
  """
  use SwarmshieldWeb, :html

  embed_templates "layouts/*"

  # ---------------------------------------------------------------------------
  # App layout (header + sidebar + main content)
  # ---------------------------------------------------------------------------

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current scope with user"

  attr :current_workspace, :map,
    default: nil,
    doc: "the current workspace struct"

  attr :user_permissions, :any,
    default: nil,
    doc: "MapSet of permission keys or :all"

  attr :active_nav, :atom,
    default: nil,
    doc: "currently active navigation item"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col bg-base-100">
      <%!-- Desktop Header --%>
      <header class="hidden lg:flex h-16 border-b-[0.5px] border-base-300 bg-base-100/95 backdrop-blur-sm sticky top-0 z-40">
        <%!-- Left: Logo area (matches sidebar width) --%>
        <div class="flex items-center gap-3 px-6 w-64 shrink-0 border-r-[0.5px] border-base-300">
          <.link navigate={~p"/dashboard"} class="flex items-center gap-3">
            <div class="flex items-center justify-center size-8 rounded-lg bg-primary/15">
              <.icon name="hero-shield-check-solid" class="size-5 text-primary" />
            </div>
            <span class="text-lg font-bold tracking-tight">SwarmShield</span>
          </.link>
        </div>

        <%!-- Right: Actions area --%>
        <div class="flex-1 flex items-center justify-between px-6">
          <%!-- Workspace indicator --%>
          <%= if @current_workspace do %>
            <div class="flex items-center gap-2">
              <div class="size-2 rounded-full bg-success animate-pulse" />
              <span class="text-sm font-medium text-base-content/60">
                {@current_workspace.name}
              </span>
            </div>
          <% else %>
            <div />
          <% end %>

          <%!-- Action cluster --%>
          <div class="flex items-center gap-3">
            <.theme_toggle />
            <.user_menu current_scope={@current_scope} />
          </div>
        </div>
      </header>

      <%!-- Mobile Header --%>
      <header class="lg:hidden flex h-14 border-b-[0.5px] border-base-300 bg-base-100 sticky top-0 z-40">
        <div class="flex items-center justify-between w-full px-4">
          <button
            type="button"
            class="p-2 -ml-2 rounded-lg hover:bg-base-200 transition-colors"
            phx-click={show_mobile_sidebar()}
            aria-label="Open navigation menu"
          >
            <.icon name="hero-bars-3" class="size-6" />
          </button>

          <.link navigate={~p"/dashboard"} class="flex items-center gap-2">
            <div class="flex items-center justify-center size-7 rounded-lg bg-primary/15">
              <.icon name="hero-shield-check-solid" class="size-4 text-primary" />
            </div>
            <span class="text-lg font-bold tracking-tight">SwarmShield</span>
          </.link>

          <.user_menu current_scope={@current_scope} />
        </div>
      </header>

      <div class="flex flex-1 relative">
        <%!-- Desktop Sidebar --%>
        <aside class="hidden lg:flex flex-col w-64 shrink-0 border-r-[0.5px] border-base-300 bg-base-100">
          <%!-- Workspace info --%>
          <%= if @current_workspace do %>
            <div class="px-4 py-3 border-b-[0.5px] border-base-300">
              <div class="text-xs font-medium uppercase tracking-wider text-base-content/50">
                Workspace
              </div>
              <div class="mt-0.5 text-sm font-semibold truncate" id="sidebar-workspace-name">
                {@current_workspace.name}
              </div>
            </div>
          <% end %>

          <%!-- Navigation --%>
          <nav class="flex-1 p-3 space-y-1 overflow-y-auto" id="sidebar-main-nav">
            <.sidebar_nav
              user_permissions={@user_permissions}
              active_nav={@active_nav}
            />
          </nav>

          <%!-- Sidebar footer: user info --%>
          <%= if @current_scope && @current_scope.user do %>
            <div class="p-4 border-t-[0.5px] border-base-300" id="sidebar-user-section">
              <div class="flex items-center gap-3">
                <div class="flex items-center justify-center size-8 rounded-full bg-primary/15 shrink-0">
                  <.icon name="hero-user-solid" class="size-4 text-primary" />
                </div>
                <div class="min-w-0 flex-1">
                  <div class="text-sm font-medium truncate">
                    {@current_scope.user.email}
                  </div>
                </div>
              </div>
              <div class="mt-2 flex gap-2">
                <.link
                  navigate={~p"/select-workspace"}
                  class="flex-1 text-center text-xs h-[32px] leading-[32px] rounded-lg bg-base-200 hover:bg-base-300 transition-colors"
                >
                  Switch
                </.link>
                <.link
                  href={~p"/users/log-out"}
                  method="delete"
                  class="flex-1 text-center text-xs h-[32px] leading-[32px] rounded-lg bg-base-200 hover:bg-error/20 hover:text-error transition-colors"
                  id="sidebar-logout-btn"
                >
                  Log out
                </.link>
              </div>
            </div>
          <% end %>
        </aside>

        <%!-- Mobile Sidebar Overlay --%>
        <div
          id="mobile-sidebar-backdrop"
          class="lg:hidden fixed inset-0 z-50 bg-black/50 hidden"
          phx-click={hide_mobile_sidebar()}
        />

        <%!-- Mobile Sidebar --%>
        <aside
          id="mobile-sidebar"
          class={[
            "lg:hidden fixed inset-y-0 left-0 z-50 w-72 bg-base-100 border-r-[0.5px] border-base-300",
            "transform -translate-x-full transition-transform duration-200 ease-in-out"
          ]}
        >
          <div class="flex items-center justify-between h-14 px-4 border-b-[0.5px] border-base-300">
            <span class="text-lg font-semibold">Menu</span>
            <button
              type="button"
              class="p-2 -mr-2 rounded-lg hover:bg-base-200 transition-colors"
              phx-click={hide_mobile_sidebar()}
            >
              <.icon name="hero-x-mark" class="size-6" />
            </button>
          </div>

          <%!-- Workspace info --%>
          <%= if @current_workspace do %>
            <div class="px-4 py-3 border-b-[0.5px] border-base-300">
              <div class="text-xs font-medium uppercase tracking-wider text-base-content/50">
                Workspace
              </div>
              <div class="mt-0.5 text-sm font-semibold truncate">
                {@current_workspace.name}
              </div>
            </div>
          <% end %>

          <nav class="flex-1 p-3 space-y-1 overflow-y-auto">
            <.sidebar_nav
              user_permissions={@user_permissions}
              active_nav={@active_nav}
            />
          </nav>

          <%!-- Mobile sidebar footer --%>
          <%= if @current_scope && @current_scope.user do %>
            <div class="p-4 border-t-[0.5px] border-base-300">
              <div class="flex items-center gap-3">
                <div class="flex items-center justify-center size-8 rounded-full bg-primary/15 shrink-0">
                  <.icon name="hero-user-solid" class="size-4 text-primary" />
                </div>
                <div class="min-w-0 flex-1">
                  <div class="text-sm font-medium truncate">
                    {@current_scope.user.email}
                  </div>
                </div>
              </div>
              <div class="mt-2 flex gap-2">
                <.link
                  navigate={~p"/select-workspace"}
                  class="flex-1 text-center text-xs h-[32px] leading-[32px] rounded-lg bg-base-200 hover:bg-base-300 transition-colors"
                >
                  Switch
                </.link>
                <.link
                  href={~p"/users/log-out"}
                  method="delete"
                  class="flex-1 text-center text-xs h-[32px] leading-[32px] rounded-lg bg-base-200 hover:bg-error/20 hover:text-error transition-colors"
                >
                  Log out
                </.link>
              </div>
            </div>
          <% end %>
        </aside>

        <%!-- Main Content --%>
        <main class="flex-1 overflow-x-hidden">
          <div class="w-full px-4 sm:px-6 lg:px-8 py-6 pb-20 lg:pb-6">
            <.flash_group flash={@flash} />
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <%!-- Mobile Bottom Navigation --%>
      <nav class="lg:hidden fixed bottom-0 left-0 right-0 h-16 bg-base-100 border-t-[0.5px] border-base-300 z-40">
        <div class="grid grid-cols-5 h-full">
          <.mobile_nav_item
            icon="hero-squares-2x2"
            label="Home"
            path={~p"/dashboard"}
            active={@active_nav == :dashboard}
          />
          <.mobile_nav_item
            icon="hero-bolt"
            label="Events"
            path={~p"/events"}
            active={@active_nav == :events}
          />
          <.mobile_nav_item
            icon="hero-cpu-chip"
            label="Agents"
            path={~p"/agents"}
            active={@active_nav == :agents}
          />
          <.mobile_nav_item
            icon="hero-chat-bubble-left-right"
            label="Delib"
            path={~p"/deliberations"}
            active={@active_nav == :deliberations}
          />
          <.mobile_nav_item
            icon="hero-clipboard-document-list"
            label="Audit"
            path={~p"/audit"}
            active={@active_nav == :audit}
          />
        </div>
      </nav>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Sidebar navigation (shared between desktop and mobile)
  # ---------------------------------------------------------------------------

  attr :user_permissions, :any, default: nil
  attr :active_nav, :atom, default: nil

  defp sidebar_nav(assigns) do
    ~H"""
    <.nav_item
      path={~p"/dashboard"}
      icon="hero-squares-2x2"
      label="Dashboard"
      active={@active_nav == :dashboard}
    />
    <.nav_item
      path={~p"/events"}
      icon="hero-bolt"
      label="Events"
      active={@active_nav == :events}
    />
    <.nav_item
      path={~p"/agents"}
      icon="hero-cpu-chip"
      label="Agents"
      active={@active_nav == :agents}
    />
    <.nav_item
      path={~p"/deliberations"}
      icon="hero-chat-bubble-left-right"
      label="Deliberations"
      active={@active_nav == :deliberations}
    />
    <%= if has_perm?(@user_permissions, "ghost_protocol:view") do %>
      <.nav_item
        path={~p"/ghost-protocol"}
        icon="hero-eye-slash"
        label="GhostProtocol"
        active={@active_nav == :ghost_protocol}
      />
    <% end %>
    <.nav_item
      path={~p"/audit"}
      icon="hero-clipboard-document-list"
      label="Audit Log"
      active={@active_nav == :audit}
    />

    <%!-- Admin section --%>
    <%= if has_perm?(@user_permissions, "admin:access") do %>
      <div class="pt-4 mt-4 border-t-[0.5px] border-base-300">
        <div class="px-3 mb-2 text-xs font-medium uppercase tracking-wider text-base-content/50">
          Admin
        </div>
        <.nav_item
          path={~p"/admin/settings"}
          icon="hero-cog-6-tooth"
          label="Settings"
          active={@active_nav == :admin_settings}
        />
        <.nav_item
          path={~p"/admin/roles"}
          icon="hero-user-group"
          label="Roles & Users"
          active={@active_nav == :admin_roles}
        />
        <.nav_item
          path={~p"/admin/users"}
          icon="hero-users"
          label="Users"
          active={@active_nav == :admin_users}
        />
        <.nav_item
          path={~p"/admin/workflows"}
          icon="hero-arrow-path"
          label="Workflows"
          active={@active_nav == :admin_workflows}
        />
      </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # Nav item component (44px touch target)
  # ---------------------------------------------------------------------------

  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class={[
        "flex items-center gap-3 px-3 h-[44px] rounded-lg text-sm font-medium transition-colors",
        if(@active,
          do: "bg-primary/10 text-primary",
          else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
        )
      ]}
    >
      <.icon name={@icon} class="size-5 shrink-0" />
      <span>{@label}</span>
    </.link>
    """
  end

  # ---------------------------------------------------------------------------
  # Mobile bottom nav item
  # ---------------------------------------------------------------------------

  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :path, :string, required: true
  attr :active, :boolean, default: false

  defp mobile_nav_item(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class={[
        "flex flex-col items-center justify-center gap-1",
        if(@active, do: "text-primary", else: "text-base-content/60")
      ]}
    >
      <.icon name={@icon} class="size-5" />
      <span class="text-xs">{@label}</span>
    </.link>
    """
  end

  # ---------------------------------------------------------------------------
  # User menu dropdown (header)
  # ---------------------------------------------------------------------------

  attr :current_scope, :map, default: nil

  defp user_menu(assigns) do
    ~H"""
    <div :if={@current_scope && @current_scope.user} class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="btn btn-ghost btn-circle">
        <div class="flex items-center justify-center size-8 rounded-full bg-primary/15">
          <.icon name="hero-user-solid" class="size-4 text-primary" />
        </div>
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-200 rounded-box z-50 w-52 p-2 shadow-lg border-[0.5px] border-base-300"
      >
        <li class="menu-title text-xs truncate">{@current_scope.user.email}</li>
        <li><.link navigate={~p"/users/settings"}>Account Settings</.link></li>
        <li><.link navigate={~p"/select-workspace"}>Switch Workspace</.link></li>
        <li>
          <.link href={~p"/users/log-out"} method="delete" class="text-error">
            Log out
          </.link>
        </li>
      </ul>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Mobile sidebar JS helpers
  # ---------------------------------------------------------------------------

  defp show_mobile_sidebar do
    %JS{}
    |> JS.show(to: "#mobile-sidebar-backdrop")
    |> JS.remove_class("-translate-x-full", to: "#mobile-sidebar")
    |> JS.add_class("translate-x-0", to: "#mobile-sidebar")
    |> JS.focus_first(to: "#mobile-sidebar")
  end

  defp hide_mobile_sidebar do
    %JS{}
    |> JS.hide(to: "#mobile-sidebar-backdrop")
    |> JS.add_class("-translate-x-full", to: "#mobile-sidebar")
    |> JS.remove_class("translate-x-0", to: "#mobile-sidebar")
  end

  # ---------------------------------------------------------------------------
  # Permission helper
  # ---------------------------------------------------------------------------

  defp has_perm?(:all, _key), do: true
  defp has_perm?(%MapSet{} = perms, key), do: MapSet.member?(perms, key)
  defp has_perm?(_, _), do: false

  # ---------------------------------------------------------------------------
  # Flash group
  # ---------------------------------------------------------------------------

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Theme toggle
  # ---------------------------------------------------------------------------

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.
  Uses JS.dispatch with detail map for clean event handling.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full h-10">
      <div class="absolute w-[33%] h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-[33%] [[data-theme=dark]_&]:left-[66%] transition-[left]" />

      <button
        class="flex items-center justify-center p-2 cursor-pointer"
        phx-click={JS.dispatch("phx:set-theme", detail: %{theme: "system"})}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex items-center justify-center p-2 cursor-pointer"
        phx-click={JS.dispatch("phx:set-theme", detail: %{theme: "light"})}
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex items-center justify-center p-2 cursor-pointer"
        phx-click={JS.dispatch("phx:set-theme", detail: %{theme: "dark"})}
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
