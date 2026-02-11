defmodule SwarmshieldWeb.Router do
  use SwarmshieldWeb, :router

  import SwarmshieldWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SwarmshieldWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug SwarmshieldWeb.Plugs.CorsHeaders
    plug SwarmshieldWeb.Plugs.ApiSecurityHeaders
    plug SwarmshieldWeb.Plugs.RequireJson
    plug SwarmshieldWeb.Plugs.ApiRateLimit
  end

  pipeline :api_auth do
    plug SwarmshieldWeb.Plugs.ApiAuth
  end

  ## Public routes (no auth required)

  scope "/", SwarmshieldWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  ## Dev-only routes (LiveDashboard, Swoosh mailbox)

  if Application.compile_env(:swarmshield, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SwarmshieldWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Auth routes (login, register, confirm - public with optional scope)

  scope "/", SwarmshieldWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{SwarmshieldWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  ## Authenticated routes (no workspace scope)
  # User settings, onboarding, workspace selector

  scope "/", SwarmshieldWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{SwarmshieldWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/onboarding", OnboardingLive, :new
      live "/select-workspace", WorkspaceSelectorLive, :index
    end

    post "/users/update-password", UserSessionController, :update_password
    post "/set-workspace", WorkspaceSessionController, :create
  end

  ## Workspace-authenticated routes
  # All routes that require an active workspace in session.
  # on_mount hooks ensure authentication AND load workspace context.

  scope "/", SwarmshieldWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :workspace_authenticated,
      on_mount: [
        {SwarmshieldWeb.Hooks.AuthHooks, :ensure_authenticated},
        {SwarmshieldWeb.Hooks.AuthHooks, :load_workspace}
      ] do
      live "/dashboard", DashboardLive, :index
      live "/events", EventsLive, :index
      live "/events/:id", EventShowLive, :show
      live "/agents", AgentsLive, :index
      live "/agents/:id", AgentShowLive, :show
      live "/deliberations", DeliberationsLive, :index
      live "/deliberations/:id", DeliberationShowLive, :show
      live "/ghost-protocol", GhostProtocolLive, :index
      live "/ghost-protocol/:id", GhostProtocolSessionLive, :show
      live "/audit", AuditLive, :index
    end
  end

  ## Workspace-admin routes
  # Requires workspace context AND admin:access permission.

  scope "/admin", SwarmshieldWeb.Admin do
    pipe_through [:browser, :require_authenticated_user]

    live_session :workspace_admin,
      on_mount: [
        {SwarmshieldWeb.Hooks.AuthHooks, :ensure_authenticated},
        {SwarmshieldWeb.Hooks.AuthHooks, :load_workspace},
        {SwarmshieldWeb.Hooks.AuthHooks, {:require_permission, "admin:access"}}
      ] do
      live "/settings", SettingsLive, :index
      live "/roles", RolesLive, :index
      live "/users", UsersLive, :index
      live "/workflows", WorkflowsLive, :index
      live "/workflows/new", WorkflowsLive, :new
      live "/workflows/:id", WorkflowShowLive, :show
      live "/workflows/:id/edit", WorkflowsLive, :edit
      live "/consensus-policies", PoliciesLive, :index
      live "/consensus-policies/new", PoliciesLive, :new
      live "/consensus-policies/:id/edit", PoliciesLive, :edit
      live "/policy-rules", PolicyRulesLive, :index
      live "/policy-rules/new", PolicyRulesLive, :new
      live "/policy-rules/:id/edit", PolicyRulesLive, :edit
      live "/detection-rules", DetectionRulesLive, :index
      live "/detection-rules/new", DetectionRulesLive, :new
      live "/detection-rules/:id/edit", DetectionRulesLive, :edit
      live "/agent-definitions", AgentDefinitionsLive, :index
      live "/agent-definitions/new", AgentDefinitionsLive, :new
      live "/agent-definitions/:id/edit", AgentDefinitionsLive, :edit
      live "/prompt-templates", PromptTemplatesLive, :index
      live "/prompt-templates/new", PromptTemplatesLive, :new
      live "/prompt-templates/:id/edit", PromptTemplatesLive, :edit
      live "/ghost-protocol-configs", GhostProtocolConfigsLive, :index
      live "/ghost-protocol-configs/new", GhostProtocolConfigsLive, :new
      live "/ghost-protocol-configs/:id/edit", GhostProtocolConfigsLive, :edit
      live "/ghost-protocol-configs/:id", GhostProtocolConfigShowLive, :show
      live "/registered-agents", RegisteredAgentsLive, :index
      live "/registered-agents/new", RegisteredAgentsLive, :new
      live "/registered-agents/:id/edit", RegisteredAgentsLive, :edit
    end
  end

  ## API routes - unauthenticated (health check)

  scope "/api/v1", SwarmshieldWeb.Api.V1 do
    pipe_through :api

    get "/health", HealthController, :index
    match :options, "/*_path", HealthController, :index
  end

  ## API routes - authenticated (Bearer token)

  scope "/api/v1", SwarmshieldWeb.Api.V1 do
    pipe_through [:api, :api_auth]

    post "/events", EventController, :create
  end
end
