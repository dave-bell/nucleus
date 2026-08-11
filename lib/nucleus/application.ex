defmodule Nucleus.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Nucleus.Backend.warn_on_local_backends()

    children = [
      NucleusWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:nucleus, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Nucleus.PubSub},
      # State for the local backend implementations, in every environment. They
      # ship in the release but are never selected in production, so gating this
      # would only add a "seed owner missing" branch for readers to handle.
      Nucleus.Backend.Seed,
      # Start a worker by calling: Nucleus.Worker.start_link(arg)
      # {Nucleus.Worker, arg},
      # Start to serve requests, typically the last entry
      NucleusWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Nucleus.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NucleusWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
