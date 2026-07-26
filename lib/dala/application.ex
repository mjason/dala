defmodule Dala.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DalaWeb.Telemetry,
      Dala.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:dala, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:dala, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Dala.PubSub},
      {Registry, keys: :unique, name: Dala.Terminal.Registry},
      Dala.Terminal.WaiterLimiter,
      Dala.Terminal.Attachments,
      Dala.Lsp.Debug,
      {DynamicSupervisor, name: Dala.Terminal.ServerSupervisor, strategy: :one_for_one},
      DalaWeb.Endpoint,
      # After the endpoint: these publish through it (Boot session updates,
      # ThemeSeeder theme_created events for the built-in presets).
      Dala.Settings.ThemeSeeder,
      Dala.Terminal.Boot,
      Dala.Accounts.Seeder,
      {AshAuthentication.Supervisor, [otp_app: :dala]}
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Dala.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DalaWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
