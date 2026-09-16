defmodule NucleusWeb.SessionController do
  @moduledoc """
  Clears the browser session for the header's Logout control (`NAV-A08`).

  A `Plug.Conn`, not a LiveView `handle_event`, is unavoidable here:
  `Plug.Conn.configure_session/2` needs a real connection, which only a
  controller (or a plug) has. This is why the `<.link>` in `layouts.ex`
  uses `method="delete"` — a real `DELETE /logout` HTTP request, not a
  `phx-click` — and why the route lives in the plain `:browser` pipeline
  in `router.ex`, outside `:assign_scope`/`:authenticated`: logging out
  must work even if scope assignment would otherwise fail.

  Because authentication is deferred
  (`docs/adr/0005-deferred-authentication.md`,
  `Nucleus.Scope.Provider.Disabled`), dropping the session does not end a
  real session — there is no token to revoke
  (`current_scope.token` is unconditionally `nil`,
  `plugs/assign_scope.ex:45`). The observable effect today is narrower:
  the session cookie is dropped, so `nav_session_id`
  (`plugs/assign_scope.ex`) is reset and `NAV-A05`'s per-session sidebar
  expand state clears — but the very next request is immediately
  re-identified as the same dev user by `NucleusWeb.Plugs.AssignScope`.
  `NAV-A09`/`NAV-A10` (real sign-out landing on a sign-in page, and
  redirecting unauthenticated visitors) are out of scope here — see
  `NAV-S4`, blocked on `AUTH-A01`.
  """

  use NucleusWeb, :controller

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/")
  end
end
