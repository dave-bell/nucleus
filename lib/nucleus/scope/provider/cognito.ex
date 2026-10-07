defmodule Nucleus.Scope.Provider.Cognito do
  @moduledoc """
  The real authentication provider (`AUTH_ENABLED=true`): builds a
  `Nucleus.Scope` from the signed-in user's session.

  Sign-in itself - the Hosted UI redirect, the code exchange, ID token
  verification, the group check - happens once, at `NucleusWeb.AuthController`'s
  callback (`Nucleus.Auth.OIDC`). By the time a scope is built here the user is
  already known, and everything about them is in the `Nucleus.Auth.Session`
  the callback wrote: their email and username, taken from the ID token's
  claims.

  `build/1` therefore needs one thing in its context besides `source_ip`:
  `session`, an already-validated `Nucleus.Auth.Session`
  (`Nucleus.Auth.SessionCheck.validate/2` is the gatekeeper; this module does
  not re-validate). Without one it answers `{:error, :no_session}` rather than
  inventing an identity.

  The scope carries no credential and no access scopes (`scopes: []`): Nucleus
  asks Cognito for `openid email` only and keeps no token. See
  `docs/adr/0040-cognito-sign-in-and-session-lifecycle.md`, which supersedes
  `docs/adr/0005-deferred-authentication.md`.

  `Nucleus.Scope.verify_provider_at_boot!/0` does not call `build/1` for this
  provider (there is no session at boot); it calls
  `Nucleus.Auth.Config.verify!/0`, so a deploy missing any Cognito setting
  fails to boot.
  """

  @behaviour Nucleus.Scope.Provider

  alias Nucleus.Auth.Session
  alias Nucleus.Scope

  @impl Nucleus.Scope.Provider
  def build(%{session: %Session{} = session} = context) do
    {:ok,
     %Scope{
       user: %{email: session.email, username: session.username},
       tenant: Scope.tenant_namespace(),
       scopes: [],
       source_ip: Map.get(context, :source_ip)
     }}
  end

  def build(_context), do: {:error, :no_session}
end
