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
if System.get_env("PHX_SERVER") do
  config :dala, DalaWeb.Endpoint, server: true
end

config :dala, DalaWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Optional authentication: when enabled, only the accounts seeded from
# DALA_USERS ("email:password,email2:password2") can sign in.
config :dala, auth_enabled: System.get_env("DALA_AUTH_ENABLED", "false") in ~w(true 1)

if data_dir = System.get_env("DALA_DATA_DIR") do
  config :dala, data_dir: data_dir
end

# Set by install.sh: the root of the versioned install tree
# (<root>/versions/<tag> + <root>/current). Its presence enables the in-app
# updater; running from source (mix) leaves it off.
config :dala, release_root: System.get_env("DALA_RELEASE_ROOT")

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
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/dala/dala.db
      """

  config :dala, Dala.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"

  # Local daemon installs serve plain http on localhost; a reverse-proxied
  # deployment sets PHX_SCHEME=https (and its own PHX_HOST).
  scheme = System.get_env("PHX_SCHEME") || "http"

  url_port =
    String.to_integer(
      System.get_env("PHX_URL_PORT") ||
        if(scheme == "https", do: "443", else: System.get_env("PORT", "4000"))
    )

  # The origin check breaks WebSockets when the app is reached by IP or an
  # alternate hostname (common for a personal terminal server on a LAN), so
  # it is opt-in for reverse-proxied setups.
  check_origin = System.get_env("PHX_CHECK_ORIGIN", "false") in ~w(true 1)

  config :dala, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Loopback-only by default — exposing a terminal server is opt-in.
  # DALA_LISTEN_IP=0.0.0.0 serves the LAN (WSL2 mirrored networking needs
  # the explicit IPv4-any; an IPv6-any `::` socket is not reliably mirrored).
  listen_ip =
    with raw = System.get_env("DALA_LISTEN_IP", "127.0.0.1"),
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
      System.get_env("TOKEN_SIGNING_SECRET") ||
        raise("Missing environment variable `TOKEN_SIGNING_SECRET`!")

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
