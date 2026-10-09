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

  ## What logging out does

  - **Signed in** (`AUTH_ENABLED=true`): ends the session in
    `Nucleus.Auth.SessionRegistry` - so a copy of the old cookie is dead too,
    not just this browser's - records `sign_out` with `reason=user`, closes the
    session's other open tabs, drops the cookie and lands on the sign-in page.
    Ending the *Cognito Hosted UI* session as well (`AUTH-A10`'s `/logout`
    redirect) is `AUTH-S2`: until then the corporate IdP may sign the user
    straight back in on their next visit, which `NucleusWeb.AuthController`
    explains.
  - **Auth disabled**: there is no session to end
    (`docs/adr/0005-deferred-authentication.md`). The cookie is dropped, so
    `nav_session_id` is reset and `NAV-A05`'s sidebar expand state clears, but
    the very next request is re-identified as the same dev user.
  """

  use NucleusWeb, :controller

  alias Nucleus.Auth.{Session, SessionCheck, SessionRegistry}
  alias Nucleus.Scope.Provider

  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    if Provider.configured() == Nucleus.Scope.Provider.Cognito do
      end_session(get_session(conn, :auth))
      conn |> configure_session(drop: true) |> redirect(to: ~p"/sign-in")
    else
      conn |> configure_session(drop: true) |> redirect(to: ~p"/")
    end
  end

  # Only the first party to end a session announces it, so a double-click on
  # Logout, or a session that had already expired, records one sign_out.
  defp end_session(%Session{} = auth) do
    case SessionRegistry.expire(SessionCheck.attrs(auth), :user) do
      {:ok, record} -> SessionRegistry.announce_expiry(record, :user)
      :already -> :ok
    end
  end

  defp end_session(_no_session), do: :ok
end
