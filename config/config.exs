# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configure the endpoint
config :nucleus, NucleusWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: NucleusWeb.ErrorHTML, json: NucleusWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Nucleus.PubSub,
  live_view: [signing_salt: "hJS7FKBE"]

# Swappable backend boundaries. One implementation per boundary, selected
# independently — see lib/nucleus/backend.ex and
# docs/adr/0002-backend-adapter-boundaries.md.
#
# These are the `real` implementations, delivered by EN-3 and EN-4. dev and test
# override both to the `.Local` implementations so a fresh clone needs no
# credentials; runtime.exs allows a per-boundary override via SECRETS_BACKEND
# and TENANT_API_BACKEND.
#
# There is deliberately no `auth` boundary. Authentication is never swappable.
config :nucleus, :backends,
  secrets: Nucleus.Secrets.Store.Aws,
  tenant_api: Nucleus.TenantApi.Http

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :nucleus, Nucleus.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  nucleus: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  nucleus: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
