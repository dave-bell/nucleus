defmodule NucleusWeb.LiveCase do
  @moduledoc """
  The composed case for tests that mount a real LiveView: `NucleusWeb.ConnCase`
  (connection + verified routes) plus `Nucleus.BackendCase` and
  `Nucleus.AuditCase` (the local-backend and audit helpers most LiveView
  tests eventually need), plus `Phoenix.LiveViewTest`.

  ## Auth is already disabled — nothing to wire up here

  `config/test.exs` selects `Nucleus.Scope.Provider.Disabled`, and
  `NucleusWeb.Plugs.AssignScope` runs it on every `:browser` request
  unconditionally (`docs/adr/0005-deferred-authentication.md`) — there is no
  "log in as a test user" step to perform, because every request already gets
  a scope. `live_secrets/2` below relies on exactly this: a plain `conn` from
  `NucleusWeb.ConnCase`'s `setup` mounts `NucleusWeb.SecretsLive` with no
  extra session setup.

  A test that needs a *specific* scope (a different tenant, email, or
  `scopes` list) puts one in the session directly before calling `live/2` —
  see `test/nucleus_web/live/scope_hook_test.exs` for the pattern:

      conn = Plug.Test.init_test_session(conn, %{current_scope: %Nucleus.Scope{...}})

  Because `Nucleus.BackendCase` wraps global, node-wide state
  (`Nucleus.Backend.Seed`, the `LOCAL_FORCE_ERROR`/`LOCAL_LATENCY_MS` env
  vars), any test using this case that seeds, mutates, or injects a fault
  must run `async: false` — see `Nucleus.BackendCase`'s moduledoc.
  """

  use ExUnit.CaseTemplate

  using opts do
    quote do
      use NucleusWeb.ConnCase, unquote(opts)
      use Nucleus.BackendCase, unquote(opts)
      use Nucleus.AuditCase, unquote(opts)

      import Phoenix.LiveViewTest
      import NucleusWeb.LiveCase
    end
  end

  @doc """
  Mounts `NucleusWeb.SecretsLive` for `environment`, the same
  `/environments/:environment/secrets` route every environment's sidebar
  link points to.

  A macro, not a function: `Phoenix.LiveViewTest.live/2` is itself a macro
  that reads the caller's `@endpoint` module attribute, so this expands
  directly into the calling test — a plain function call could not see it.
  """
  defmacro live_secrets(conn, environment) do
    quote do
      Phoenix.LiveViewTest.live(unquote(conn), "/environments/#{unquote(environment)}/secrets")
    end
  end
end
