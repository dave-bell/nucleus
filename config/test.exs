import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :nucleus, NucleusWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "fqN9qsrIaw+4rvqsEU1fnPdasjblIMGODWFsQOeSrg6HrtbceehaEhzJrTm5FpKU",
  server: false

# In test we don't send emails
config :nucleus, Nucleus.Mailer, adapter: Swoosh.Adapters.Test

# The suite runs with no credentials and no external services. Tests that need a
# different implementation set it themselves with Application.put_env/3.
config :nucleus, :backends,
  secrets: Nucleus.Secrets.Store.Local,
  tenant_api: Nucleus.TenantApi.Local,
  m2m: Nucleus.M2M.Clients.Local

# Deploy-time cluster/deployment segments of the Parameter Store path — see
# config/dev.exs and lib/nucleus/secrets/path.ex.
config :nucleus, Nucleus.Secrets.Path,
  cluster_name: "local-cluster",
  deployment_name: "local-deployment"

# Tests assert on emitted audit records via Nucleus.Audit.Sink.Test's
# registered process, rather than parsing :stderr.
config :nucleus, Nucleus.Audit, sink: Nucleus.Audit.Sink.Test

# A fixed, deliberately different-from-the-default dev identity, so a test
# asserting the configured value is not accidentally passing against the
# same literal used elsewhere.
config :nucleus, Nucleus.Scope.Provider.Disabled,
  email: "test-dev@example.com",
  scopes: ["test-scope"]

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# PhoenixTest (EN-8) needs to know which endpoint to route visited paths
# through — see test/support/conn_case.ex.
config :phoenix_test, :endpoint, NucleusWeb.Endpoint
