defmodule Nucleus.Scope.Provider.Disabled do
  @moduledoc """
  The default scope provider: auth is disabled, identity is a single
  configured dev user.

  Never fails — there is no external call to fail. The dev identity comes
  from application configuration (`config/dev.exs`; `config/test.exs`
  overrides it for tests that need a specific value), not an environment
  variable: with `AUTH_ENABLED=true`, the equivalent values are sourced from
  the minted JWT instead, so there is nothing for a `DEV_USER_EMAIL`-style
  runtime variable to still be doing in a deployed environment.

      config :nucleus, Nucleus.Scope.Provider.Disabled,
        email: "dev@example.com",
        scopes: []

  `Nucleus.Scope.verify_provider_at_boot!/0` logs a prominent warning naming
  this identity on every boot where this provider is selected — see
  `docs/adr/0005-deferred-authentication.md`.
  """

  @behaviour Nucleus.Scope.Provider

  alias Nucleus.Scope

  @default_email "dev@example.com"

  @impl Nucleus.Scope.Provider
  def build(context) when is_map(context) do
    config = Application.get_env(:nucleus, __MODULE__, [])

    scope = %Scope{
      user: %{email: Keyword.get(config, :email, @default_email), username: nil},
      tenant: Scope.tenant_namespace(),
      token: nil,
      scopes: Keyword.get(config, :scopes, []),
      source_ip: Map.get(context, :source_ip)
    }

    {:ok, scope}
  end
end
