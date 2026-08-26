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
#     PHX_SERVER=true bin/nucleus start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :nucleus, NucleusWeb.Endpoint, server: true
end

config :nucleus, NucleusWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Per-boundary backend override: SECRETS_BACKEND / TENANT_API_BACKEND /
# M2M_BACKEND, each "real" or "local". Unset boundaries keep whatever the
# compile-time config chose — "real" in prod, "local" in dev and test.
#
# Selection is per boundary, not one global switch: Parameter Store needs a
# Terraform-provisioned cross-account IAM role, and a developer working only on
# environment listing should not need one. There is deliberately no
# AUTH_BACKEND — authentication is never swappable.
#
# Nucleus.Backend is the single source of truth for which module means "real"
# and which means "local"; runtime.exs runs after compilation, so it can ask.
for boundary <- Nucleus.Backend.boundaries(),
    mode = System.get_env(Nucleus.Backend.env_var(boundary)),
    mode not in [nil, ""] do
  config :nucleus, :backends, [{boundary, Nucleus.Backend.impl_for_mode!(boundary, mode)}]
end

# The tenant's backing API. Needed only when the :tenant_api boundary is running
# its real implementation — a developer running fully local must not have to
# invent a URL to boot the app.
#
# There is deliberately **no boot-time check** that the base URL is present. A
# missing one surfaces as `%Nucleus.Backend.Error{kind: :not_configured}` on the
# call, because the adapter must never crash and must never fall back to a
# default host. A boot check could not be written usefully anyway: prod defaults
# to the real implementation with TENANT_API_BACKEND *unset*, so it would have to
# fire on a variable's absence rather than on its value.
#
# The timeouts are different — a value that is present but not a number is a
# typo, and `String.to_integer/1` raising at boot is the right response to it.
tenant_api_config =
  [
    base_url: System.get_env("TENANT_API_BASE_URL"),
    connect_timeout_ms: System.get_env("TENANT_API_CONNECT_TIMEOUT_MS"),
    receive_timeout_ms: System.get_env("TENANT_API_RECEIVE_TIMEOUT_MS")
  ]
  |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  |> Enum.map(fn
    {:base_url, value} -> {:base_url, value}
    {key, value} -> {key, String.to_integer(value)}
  end)

if tenant_api_config != [] do
  config :nucleus, Nucleus.TenantApi.Http, tenant_api_config
end

# The cluster/deployment segments of every Parameter Store path
# (Nucleus.Secrets.Path.build/2) — required unconditionally, in every
# environment, because both the local and the real :secrets implementation
# call it (the local implementation synthesises plausible paths and ARNs so
# SEC-A02's copy affordances are exercisable locally too, see
# Nucleus.Secrets.Store.Local). config/dev.exs and config/test.exs hardcode
# obvious placeholder defaults, matching the TENANT_NAMESPACE precedent, so a
# fresh clone needs no env var. Production has no such placeholder — a missing
# CLUSTER_NAME or DEPLOYMENT_NAME there is a deployment mistake, not a runtime
# condition, so it raises at boot rather than building a path that could
# silently address the wrong tenant's parameters.
if config_env() == :prod do
  cluster_name =
    System.get_env("CLUSTER_NAME") ||
      raise "environment variable CLUSTER_NAME is missing"

  deployment_name =
    System.get_env("DEPLOYMENT_NAME") ||
      raise "environment variable DEPLOYMENT_NAME is missing"

  config :nucleus, Nucleus.Secrets.Path,
    cluster_name: cluster_name,
    deployment_name: deployment_name
end

# Cross-account AWS access for the :secrets boundary's real implementation —
# read only when that implementation is actually selected (the check runs
# after the per-boundary override loop above, so SECRETS_BACKEND has already
# taken effect). A developer running fully local, the dev/test default, must
# not have to invent a role ARN to boot the app. AWS_STS_EXTERNAL_ID is
# optional — only required if the role itself demands one.
if Application.get_env(:nucleus, :backends, [])[:secrets] ==
     Nucleus.Backend.impl_for_mode!(:secrets, :real) do
  role_arn =
    System.get_env("TENANT_ROLE_ARN") ||
      raise "environment variable TENANT_ROLE_ARN is missing (required when the :secrets boundary runs its real implementation)"

  region =
    System.get_env("AWS_REGION") ||
      raise "environment variable AWS_REGION is missing (required when the :secrets boundary runs its real implementation)"

  config :nucleus, Nucleus.Secrets.Store.Aws,
    role_arn: role_arn,
    region: region,
    external_id: System.get_env("AWS_STS_EXTERNAL_ID")
end

# Cognito App Client operations for the :m2m boundary's real implementation —
# read only when that implementation is actually selected, same reasoning as
# the :secrets block above. COGNITO_USER_POOL_ID is read unconditionally,
# below, with no boot check (out of scope for EN-10 — see issue #33); a nil
# value is %Nucleus.Backend.Error{kind: :not_configured} at call time, never a
# crash. COGNITO_REGION has **no fallback to AWS_REGION** — the two boundaries'
# regions are independently configured, deliberately
# (docs/adr/0015-shared-aws-identity-seam.md). COGNITO_STS_EXTERNAL_ID is
# optional, mirroring AWS_STS_EXTERNAL_ID.
if Application.get_env(:nucleus, :backends, [])[:m2m] ==
     Nucleus.Backend.impl_for_mode!(:m2m, :real) do
  cognito_role_arn =
    System.get_env("COGNITO_ROLE_ARN") ||
      raise "environment variable COGNITO_ROLE_ARN is missing (required when the :m2m boundary runs its real implementation)"

  cognito_region =
    System.get_env("COGNITO_REGION") ||
      raise "environment variable COGNITO_REGION is missing (required when the :m2m boundary runs its real implementation)"

  config :nucleus, Nucleus.M2M.Clients.Cognito,
    role_arn: cognito_role_arn,
    region: cognito_region,
    external_id: System.get_env("COGNITO_STS_EXTERNAL_ID")
end

if user_pool_id = System.get_env("COGNITO_USER_POOL_ID") do
  config :nucleus, Nucleus.M2M.Clients.Cognito, user_pool_id: user_pool_id
end

# Nomad job reads for the :nomad_jobs boundary's real implementation — read
# only when that implementation is actually selected, same reasoning as the
# :secrets and :m2m blocks above. Both NOMAD_ADDR and NOMAD_TOKEN are
# documented as Required in docs/requirements/Platform-Operations.md, so a
# real implementation with either missing raises at boot rather than
# reaching :not_configured on the first call — a developer running fully
# local, the dev/test default, must not have to invent either to boot the
# app, which is exactly why this block is gated on the real implementation
# being selected.
if Application.get_env(:nucleus, :backends, [])[:nomad_jobs] ==
     Nucleus.Backend.impl_for_mode!(:nomad_jobs, :real) do
  nomad_addr =
    System.get_env("NOMAD_ADDR") ||
      raise "environment variable NOMAD_ADDR is missing (required when the :nomad_jobs boundary runs its real implementation)"

  nomad_token =
    System.get_env("NOMAD_TOKEN") ||
      raise "environment variable NOMAD_TOKEN is missing (required when the :nomad_jobs boundary runs its real implementation)"

  config :nucleus, Nucleus.Nomad.Transport,
    base_url: nomad_addr,
    token: nomad_token
end

# Audit sink overrides. AUDIT_FORMAT is "json" or "text" (see
# Nucleus.Audit.Format); anything else raises at boot rather than silently
# falling back — a typo here should not silently change what a compliance
# pipeline receives. AUDIT_DEVICE is "stdout", "stderr", or a file path
# opened once at boot in append mode.
if audit_format = System.get_env("AUDIT_FORMAT") do
  format =
    case Nucleus.Audit.Format.cast(audit_format) do
      {:ok, format} -> format
      :error -> raise "AUDIT_FORMAT must be \"json\" or \"text\", got: #{inspect(audit_format)}"
    end

  config :nucleus, Nucleus.Audit, format: format
end

if audit_device = System.get_env("AUDIT_DEVICE") do
  device =
    case Nucleus.Audit.Sink.Device.cast_device_name(audit_device) do
      {:ok, device} -> device
      :error -> File.open!(audit_device, [:append, :utf8])
    end

  config :nucleus, Nucleus.Audit, device: device
end

# Identity/scope seam (EN-6). AUTH_ENABLED selects the scope provider;
# "false" or unset (the default) keeps Nucleus.Scope.Provider.Disabled.
# "true" switches to Nucleus.Scope.Provider.Cognito, a stub that raises
# unconditionally — Nucleus.Scope.verify_provider_at_boot!/0 calls it during
# Nucleus.Application.start/2, so a misread flag fails the boot rather than
# silently keeping the disabled provider. Anything else raises here, at boot,
# rather than being silently treated as "false" — same reasoning as
# AUDIT_FORMAT above. See docs/adr/0005-deferred-authentication.md.
case System.get_env("AUTH_ENABLED") do
  nil ->
    :ok

  "false" ->
    :ok

  "true" ->
    config :nucleus, Nucleus.Scope, provider: Nucleus.Scope.Provider.Cognito

  other ->
    raise "AUTH_ENABLED must be \"true\" or \"false\", got: #{inspect(other)}"
end

# The tenant this deployment serves, carried on every Nucleus.Scope (EN-5's
# audit records and EN-6's identity display both read it). No boot-time
# presence check, same reasoning as TENANT_API_BASE_URL above — the
# config.exs default ("local") is a deliberately obvious placeholder, not a
# host to fail loudly on the absence of.
if tenant_namespace = System.get_env("TENANT_NAMESPACE") do
  config :nucleus, Nucleus.Scope, tenant_namespace: tenant_namespace
end

# The M2M deny-list's reserved client-name suffixes (M2M-S1 Decision 2).
# `Nucleus.M2M.DenyList.parse/1` is pure and already handles unset/blank
# (`:unset`) and the `none` sentinel — only an `{:ok, suffixes}` result sets
# the app-env key here. An absent key, not a raised boot error, is
# `Nucleus.M2M.DenyList.suffixes/0`'s own `:not_configured` signal
# (Nucleus.Secrets.Path's fail-closed-at-call-time precedent) — config/dev.exs
# and config/test.exs hardcode the parsed default so neither ever reaches
# this branch.
case Nucleus.M2M.DenyList.parse(System.get_env("M2M_DENY_SUFFIXES")) do
  {:ok, suffixes} -> config :nucleus, Nucleus.M2M.DenyList, suffixes: suffixes
  :unset -> :ok
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :nucleus, NucleusWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/nucleus_web/router\.ex$"E,
        ~r"lib/nucleus_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
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

  host = System.get_env("PHX_HOST") || "example.com"

  config :nucleus, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :nucleus, NucleusWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :nucleus, NucleusWeb.Endpoint,
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
  #     config :nucleus, NucleusWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :nucleus, Nucleus.Mailer,
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
