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

# Per-boundary backend override: SECRETS_BACKEND / TENANT_API_BACKEND, each
# "real" or "local". Unset boundaries keep whatever the compile-time config
# chose — "real" in prod, "local" in dev and test.
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
