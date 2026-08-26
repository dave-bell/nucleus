defmodule NucleusWeb.Router do
  use NucleusWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NucleusWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Assigns `current_scope` (EN-6) — separate from :browser so a route can
  # opt out (there are none yet; every future authenticated LiveView goes
  # through this via the :authenticated live_session below).
  pipeline :assign_scope do
    plug NucleusWeb.Plugs.AssignScope
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NucleusWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", NucleusWeb do
    pipe_through [:browser, :assign_scope]

    # `on_mount` at the live_session level, not per LiveView, so no future
    # view can be added under this scope without current_scope or the
    # sidebar's environment list (AGENTS.md,
    # docs/adr/0005-deferred-authentication.md). EnvironmentsHook runs after
    # ScopeHook — it reads current_scope.token off the socket.
    #
    # SecretsLive is a placeholder (SEC-S1/S2 own the real feature) so this
    # route compiles and Layouts.app's sidebar has somewhere real to link
    # environments to, per this ticket's own plan.
    live_session :authenticated,
      on_mount: [{NucleusWeb.ScopeHook, :assign}, {NucleusWeb.EnvironmentsHook, :assign}] do
      # No conflict with the detail route below — Phoenix disambiguates on
      # the trailing `/secrets` segment.
      live "/environments/:environment", EnvironmentsLive, :show
      live "/environments/:environment/secrets", SecretsLive, :index

      # Two modules, not one switching on `handle_params/3` — M2M-S2
      # (#35) Decision 7, the `phx.gen.live` module split
      # (`deps/phoenix/priv/templates/phx.gen.live/{index,show}.ex.eex`):
      # `Index` and `Show` are reached only by `navigate`, never a `patch`
      # between each other, so there is nothing for a shared module to
      # re-validate. `Show` ships as a stub in this ticket — M2M-S3 (#36)
      # replaces its body without touching this route or `Index`.
      live "/m2m/clients", M2MClientsLive.Index, :index
      live "/m2m/clients/:client_id", M2MClientsLive.Show, :show

      # Single module, no Index/Show split — APP-S1 (#58), see
      # `NucleusWeb.ApplicationsLive`'s moduledoc.
      live "/applications", ApplicationsLive, :index
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", NucleusWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:nucleus, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    #
    # Acceptable here specifically because this whole block is behind
    # Application.compile_env(:nucleus, :dev_routes) — false in every
    # non-dev release config (config/{prod,test}.exs never set it), so it
    # cannot compile into a production build regardless of runtime
    # configuration. There is still no :auth boundary to gate it behind
    # (EN-6/docs/adr/0005-deferred-authentication.md) — this guard is the
    # only thing standing between LiveDashboard and the internet, and it
    # holds because it's a compile-time, not runtime, switch.
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: NucleusWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
