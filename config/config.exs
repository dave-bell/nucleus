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
# These are the `real` implementations, delivered by EN-3, EN-4, EN-10, EN-11,
# and EN-12. dev and test override all five to the `.Local` implementations so
# a fresh clone needs no credentials; runtime.exs allows a per-boundary
# override via SECRETS_BACKEND, TENANT_API_BACKEND, M2M_BACKEND,
# NOMAD_JOBS_BACKEND, and NOMAD_VARS_BACKEND.
#
# There is deliberately no `auth` boundary. Authentication is never swappable.
config :nucleus, :backends,
  secrets: Nucleus.Secrets.Store.Aws,
  tenant_api: Nucleus.TenantApi.Http,
  m2m: Nucleus.M2M.Clients.Cognito,
  nomad_jobs: Nucleus.NomadJobs.Http,
  nomad_vars: Nucleus.NomadVars.Store.Http

# The tenant's backing API — the authority on environments. `base_url` has no
# default on purpose: there is no sensible host to fall back to, and a boundary
# that quietly talks to the wrong one is worse than one that reports
# `:not_configured`. runtime.exs fills it from TENANT_API_BASE_URL.
#
# Connect and receive timeouts are separate. They fail for different reasons, and
# an unbounded call here would hang a LiveView mount.
config :nucleus, Nucleus.TenantApi.Http,
  base_url: nil,
  connect_timeout_ms: 5_000,
  receive_timeout_ms: 10_000

# The cluster/deployment segments of every Parameter Store path — see
# lib/nucleus/secrets/path.ex. No default here: unlike tenant_namespace above,
# there is no single obvious placeholder that stays correct in every
# environment, dev and test included, so each hardcodes its own literal below
# and runtime.exs requires both unconditionally in production.
config :nucleus, Nucleus.Secrets.Path,
  cluster_name: nil,
  deployment_name: nil

# The tenant's cross-account role for Parameter Store access — see
# lib/nucleus/secrets/store/aws.ex. No default: there is no sensible role to
# assume by default, and runtime.exs requires this only when the :secrets
# boundary is running its real implementation.
config :nucleus, Nucleus.Secrets.Store.Aws,
  role_arn: nil,
  region: nil,
  external_id: nil

# The tenant's cross-account role for Cognito App Client operations — see
# lib/nucleus/m2m/clients/cognito.ex. No default, matching
# Nucleus.Secrets.Store.Aws above: runtime.exs requires COGNITO_ROLE_ARN and
# COGNITO_REGION only when the :m2m boundary is running its real
# implementation. COGNITO_USER_POOL_ID carries no such boot check (out of
# scope for EN-10) — a nil value is :not_configured, never a crash.
config :nucleus, Nucleus.M2M.Clients.Cognito,
  user_pool_id: nil,
  role_arn: nil,
  region: nil,
  external_id: nil

# The tenant's Nomad cluster — see lib/nucleus/nomad/transport.ex. Both
# NOMAD_ADDR and NOMAD_TOKEN are documented as Required in
# docs/requirements/Platform-Operations.md, but there is no boot-time check
# here, matching Nucleus.TenantApi.Http's base_url reasoning: a missing value
# surfaces as `:not_configured` on the call, never a crash and never a
# request to a default host. NOMAD_TOKEN absent means every request omits
# the X-Nomad-Token header entirely, never an empty one.
config :nucleus, Nucleus.Nomad.Transport,
  base_url: nil,
  token: nil,
  connect_timeout_ms: 5_000,
  receive_timeout_ms: 10_000

# Identity/scope seam (EN-6) — auth is deliberately deferred; see
# lib/nucleus/scope.ex and docs/adr/0005-deferred-authentication.md.
#
# Nucleus.Scope.Provider.Disabled is the default in every environment: it
# never fails and returns a single configured dev identity. AUTH_ENABLED=true
# switches `:provider` to Nucleus.Scope.Provider.Cognito in runtime.exs, which
# raises unconditionally — there is no AUTH_ENABLED default here because
# "false" and "unset" must behave identically, and the config default already
# gives that.
#
# tenant_namespace has no default host to guess at, so "local" is a
# deliberately obvious placeholder — runtime.exs fills it from
# TENANT_NAMESPACE in any environment where the tenant is known.
config :nucleus, Nucleus.Scope, tenant_namespace: "local"

# Compliance audit trail (SOC2 CC7.2 / HIPAA 164.312(b)) — bypasses Logger and
# writes synchronously to a dedicated sink, distinct from application logs
# (AUD-A06/A07). See lib/nucleus/audit.ex and
# docs/adr/0004-audit-emission.md. dev overrides format to :text; test
# overrides sink to Nucleus.Audit.Sink.Test; runtime.exs reads AUDIT_FORMAT
# and AUDIT_DEVICE.
config :nucleus, Nucleus.Audit,
  sink: Nucleus.Audit.Sink.Device,
  format: :json,
  device: :stderr

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
