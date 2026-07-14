defmodule DalaWeb.Router do
  use DalaWeb, :router

  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DalaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :load_from_session
  end

  pipeline :spa do
    plug DalaWeb.Plugs.RequireAuth, mode: :page
  end

  pipeline :rpc do
    plug DalaWeb.Plugs.RequireAuth, mode: :api
    plug :set_actor, :user
  end

  scope "/", DalaWeb do
    pipe_through [:browser, :spa]

    get "/", PageController, :index
    get "/files/raw", FileController, :raw
    get "/lsp/ws", LspController, :ws
    get "/files/watch", FileController, :watch
  end

  scope "/", DalaWeb do
    pipe_through :browser

    # Self-guarding: signed-in users AND loopback peers (AI agents run on
    # this host and already own a shell — reading LSP health adds nothing).
    get "/lsp/debug", LspController, :debug

    # Public: lets the SPA detect a server upgrade after a socket reconnect
    # (see VersionController for why this needs no auth).
    get "/version", VersionController, :show
  end

  scope "/", DalaWeb do
    pipe_through [:browser, :rpc]

    post "/rpc/run", AshTypescriptRpcController, :run
    post "/rpc/validate", AshTypescriptRpcController, :validate
    post "/files/upload", FileController, :upload
  end

  scope "/", DalaWeb do
    pipe_through :browser

    auth_routes AuthController, Dala.Accounts.User, path: "/auth"
    sign_out_route AuthController

    # layout: false drops the default Phoenix app header (white navbar) —
    # the sign-in override styles the full viewport dark by itself.
    sign_in_route auth_routes_prefix: "/auth",
                  layout: false,
                  on_mount: [{DalaWeb.LiveUserAuth, :live_no_user}],
                  overrides: [
                    DalaWeb.AuthOverrides,
                    Elixir.AshAuthentication.Phoenix.Overrides.Default
                  ]
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:dala, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DalaWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  if Application.compile_env(:dala, :dev_routes) do
    import AshAdmin.Router

    scope "/admin" do
      pipe_through :browser

      ash_admin "/"
    end
  end
end
