defmodule Nucleus.Scope.Provider.Cognito do
  @moduledoc """
  The real authentication provider — a stub.

  None of `AUTH-A01`–`AUTH-A11` are implemented (Cognito Hosted UI, PKCE,
  token validation, group membership, silent refresh, sign-out, identity
  display). Selecting this provider (`AUTH_ENABLED=true`) is only meant to
  fail loudly at boot, via `Nucleus.Scope.verify_provider_at_boot!/0` calling
  `build/1` unconditionally during `Nucleus.Application.start/2` — booting
  insecure because a flag was misread is the failure mode this is designed to
  rule out.

  See `docs/adr/0005-deferred-authentication.md` and the wiki's
  [Authentication & Access](https://github.com/dave-bell/nucleus/wiki/Authentication-and-Access)
  page for the deferred design.
  """

  @behaviour Nucleus.Scope.Provider

  @impl Nucleus.Scope.Provider
  def build(_context) do
    raise """
    Real authentication is not implemented; see AUTH-A01..A11.

    AUTH_ENABLED=true selected Nucleus.Scope.Provider.Cognito, but EN-6 only
    reserves this seam — it does not implement sign-in, token validation, or
    group membership (see docs/adr/0005-deferred-authentication.md). Set
    AUTH_ENABLED=false (or leave it unset) until the auth ticket lands.
    """
  end
end
