import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/dala start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
# Server configuration comes from ~/.config/dala/config.jsonc (see
# Dala.RuntimeConfig) — PROD ONLY: development and test configure through
# env/config files in the repo, and must never pick up a machine's personal
# server config. Env precedence: DALA_-prefixed (deliberate, dev) > file >
# bare legacy names (old dala.env installs) > default.
cfg = if config_env() == :prod, do: Dala.RuntimeConfig.load(), else: %{}

if System.get_env("DALA_SERVER") || System.get_env("PHX_SERVER") || cfg["server"] == true do
  config :dala, DalaWeb.Endpoint, server: true
end

config :dala, DalaWeb.Endpoint,
  http: [port: Dala.RuntimeConfig.get_int(cfg, {"DALA_PORT", "PORT"}, "port", 4000)]

# Optional authentication: when enabled, only the bootstrapped accounts
# (auth.users in config.jsonc, or legacy DALA_USERS) can sign in.
auth = cfg["auth"] || %{}

config :dala,
  auth_enabled: System.get_env("DALA_AUTH_ENABLED", "") in ~w(true 1) or auth["enabled"] == true

config :dala,
  bootstrap_users: System.get_env("DALA_USERS") || auth["users"] || "",
  bootstrap_users_reset:
    System.get_env("DALA_USERS_RESET") in ~w(true 1) or auth["usersReset"] == true

# The MCP (Model Context Protocol) server is enabled/disabled at RUNTIME from
# the web Settings panel, and its bearer token is server-generated — both live
# in `Dala.Settings.Mcp` (a DB singleton), not the environment. See docs/mcp.md.

# Dev/test keep their own data_dir defaults (config.exs) unless explicitly
# overridden; prod resolves file/XDG so no env var is required.
if config_env() == :prod do
  config :dala, data_dir: Dala.RuntimeConfig.data_dir(cfg)
else
  if data_dir = System.get_env("DALA_DATA_DIR") do
    config :dala, data_dir: data_dir
  end
end

config :dala, file_limits: Dala.RuntimeConfig.file_limits(cfg)

# Set by install.sh (config.jsonc releaseRoot / legacy env): the root of the
# versioned install tree. Its presence enables the in-app updater; running
# from source (mix) leaves it off.
config :dala, release_root: Dala.RuntimeConfig.get(cfg, "DALA_RELEASE_ROOT", "releaseRoot")
config :dala, service_name: Dala.RuntimeConfig.get(cfg, "DALA_SERVICE", "serviceName")

config :dala,
  update_repo: Dala.RuntimeConfig.get(cfg, "DALA_UPDATE_REPO", "updateRepo", "mjason/dala")

# Legacy-mode detection: a prod install still configured purely through
# dala.env (no config file at all). The web UI surfaces a migration nudge —
# env-based config is for development; production should carry none.
config :dala,
  legacy_env_config:
    config_env() == :prod and cfg == %{} and System.get_env("SECRET_KEY_BASE") != nil

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :dala, DalaWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/dala_web/router\.ex$"E,
        ~r"lib/dala_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    Dala.RuntimeConfig.get(cfg, {"DALA_DATABASE_PATH", "DATABASE_PATH"}, "databasePath") ||
      Path.join(Dala.RuntimeConfig.data_dir(cfg), "dala.db")

  config :dala, Dala.Repo,
    database: database_path,
    pool_size: Dala.RuntimeConfig.get_int(cfg, {"DALA_POOL_SIZE", "POOL_SIZE"}, "poolSize", 10)

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  # Secrets never live in the config file: generated on first boot and
  # persisted 0600 at <data_dir>/secrets.json. Legacy env still wins.
  secret_key_base =
    Dala.RuntimeConfig.secret(cfg, {"DALA_SECRET_KEY_BASE", "SECRET_KEY_BASE"}, "secretKeyBase")

  host = Dala.RuntimeConfig.get(cfg, {"DALA_HOST", "PHX_HOST"}, "host", "localhost")

  # Local daemon installs serve plain http on localhost; a reverse-proxied
  # deployment sets scheme https (and its own host).
  scheme = Dala.RuntimeConfig.get(cfg, {"DALA_SCHEME", "PHX_SCHEME"}, "scheme", "http")

  url_port =
    Dala.RuntimeConfig.get_int(cfg, {"DALA_URL_PORT", "PHX_URL_PORT"}, "urlPort", nil) ||
      if(scheme == "https",
        do: 443,
        else: Dala.RuntimeConfig.get_int(cfg, {"DALA_PORT", "PORT"}, "port", 4000)
      )

  # The origin check breaks WebSockets when the app is reached by IP or an
  # alternate hostname (common for a personal terminal server on a LAN), so
  # it is opt-in for reverse-proxied setups.
  check_origin =
    Dala.RuntimeConfig.get_bool(
      cfg,
      {"DALA_CHECK_ORIGIN", "PHX_CHECK_ORIGIN"},
      "checkOrigin",
      false
    )

  config :dala,
         :dns_cluster_query,
         Dala.RuntimeConfig.get(cfg, "DNS_CLUSTER_QUERY", "dnsClusterQuery")

  # Loopback-only by default — exposing a terminal server is opt-in.
  # DALA_LISTEN_IP=0.0.0.0 serves the LAN (WSL2 mirrored networking needs
  # the explicit IPv4-any; an IPv6-any `::` socket is not reliably mirrored).
  listen_ip =
    with raw = Dala.RuntimeConfig.get(cfg, "DALA_LISTEN_IP", "listenIp", "127.0.0.1"),
         {:ok, ip} <- raw |> String.to_charlist() |> :inet.parse_address() do
      ip
    else
      _ -> raise "invalid DALA_LISTEN_IP (expected an IPv4/IPv6 address)"
    end

  config :dala, DalaWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    check_origin: check_origin,
    http: [ip: listen_ip],
    secret_key_base: secret_key_base

  config :dala,
    token_signing_secret:
      Dala.RuntimeConfig.secret(
        cfg,
        {"DALA_TOKEN_SIGNING_SECRET", "TOKEN_SIGNING_SECRET"},
        "tokenSigningSecret"
      )

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :dala, DalaWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :dala, DalaWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :dala, Dala.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
