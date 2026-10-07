defmodule NucleusWeb.AuthController do
  @moduledoc """
  Sign-in with SSO (`AUTH-A01`..`A04`): the sign-in page, the redirect to the
  Cognito Hosted UI, and the callback that turns an authorization code into a
  session.

  ## The callback

  Everything that can go wrong at the callback ends in a generic failure page
  (or, for a group failure, an access-denied page), a recorded `auth_failure`,
  and **no session** - never a crash. `auth_failure` is reserved for exactly
  this: a routine "never signed in" visit is not a failure and is not audited
  (`AUTH-A06`).

  | Condition | `reason` | Page |
  |---|---|---|
  | `?error=` from the IdP (cancelled, refused) | `idp_error:<code>` | failure |
  | no pending sign-in, or `state` does not match | `state_missing` / `state_mismatch` | failure |
  | no `code` | `missing_code` | failure |
  | token endpoint non-200, unreachable, no ID token | `token_exchange_failed`, `token_endpoint_unreachable` | failure |
  | ID token signature or claims invalid, nonce mismatch | `invalid_id_token:<why>` | failure |
  | not in `COGNITO_ALLOWED_GROUP` | `not_in_authorized_group` | access denied |

  On success: the session is renewed and replaced wholesale (nothing from before
  sign-in survives into it), holds the user's id, email and `signed_in_at` and
  **no token**, `sign_in` is recorded, and the browser goes to the page it
  originally asked for (`AUTH-A03`) or `/`.

  ## Silent re-sign-in

  The Hosted UI federates to the corporate identity provider. If that
  provider's own session is still alive, a user who is sent back through here
  after their Nucleus session ended - idle, max age, or even a deliberate
  sign-out - is signed straight back in with no prompt. That is the IdP doing
  its job, not a bug in this callback, but it is what a "silent" re-sign-in
  hits: sign-out (`AUTH-A10`, AUTH-S2) has to end the Hosted UI session too, via
  its `/logout` endpoint, to mean anything.

  ## Auth disabled

  With `AUTH_ENABLED=false` there is nothing to sign in to, and these routes
  send the browser to `/`.
  """

  use NucleusWeb, :controller

  alias Nucleus.Audit
  alias Nucleus.Auth.{OIDC, Session, SessionCheck, SessionRegistry}
  alias Nucleus.Scope
  alias Nucleus.Scope.Provider
  alias NucleusWeb.ReturnTo

  plug :require_sign_in_enabled

  # Only a code like "access_denied" is echoed into an audit reason; the
  # parameter is attacker-controlled.
  @idp_error_code ~r/\A[a-z_]{1,40}\z/

  @doc "`GET /sign-in` (`AUTH-A01`)."
  @spec new(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def new(conn, params) do
    return_to = ReturnTo.sanitize(params["return_to"])

    case SessionCheck.validate(get_session(conn)) do
      {:ok, _session} ->
        redirect(conn, to: return_to || ~p"/")

      {:error, _no_valid_session} ->
        # Anything left in the cookie is dead; start the page from a clean one.
        # `clear_session`, not `configure_session(drop: true)`: a dropped session
        # also drops the CSRF secret this page's form is about to need.
        conn
        |> clear_session()
        |> render(:new, return_to: return_to)
    end
  end

  @doc "`POST /sign-in` - start the Authorization Code flow (`AUTH-A02`)."
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    request = OIDC.authorization_request()

    conn
    |> put_session(:auth_pending, %{
      state: request.state,
      nonce: request.nonce,
      code_verifier: request.code_verifier,
      return_to: ReturnTo.sanitize(params["return_to"])
    })
    |> redirect(external: request.url)
  end

  @doc "`GET /auth/callback` (`AUTH-A02`, `AUTH-A04`)."
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, params) do
    # One shot: whatever happens next, this sign-in attempt is spent.
    pending = get_session(conn, :auth_pending)
    conn = delete_session(conn, :auth_pending)

    with :ok <- check_idp_error(params),
         {:ok, pending} <- check_pending(pending),
         :ok <- check_state(params, pending),
         {:ok, code} <- fetch_code(params),
         {:ok, id_token} <- exchange(code, pending),
         {:ok, claims} <- verify(id_token, pending),
         :ok <- check_group(claims) do
      sign_in(conn, claims, pending.return_to)
    else
      {:denied, claims} -> deny(conn, claims)
      {:error, reason} -> fail(conn, reason)
    end
  end

  # --- callback steps ---------------------------------------------------------

  defp check_idp_error(%{"error" => code}) do
    code = if is_binary(code) and code =~ @idp_error_code, do: code, else: "unknown"
    {:error, "idp_error:" <> code}
  end

  defp check_idp_error(_params), do: :ok

  defp check_pending(%{state: _, nonce: _, code_verifier: _} = pending), do: {:ok, pending}
  defp check_pending(_none), do: {:error, "state_missing"}

  defp check_state(%{"state" => state}, %{state: expected}) when is_binary(state) do
    if Plug.Crypto.secure_compare(state, expected), do: :ok, else: {:error, "state_mismatch"}
  end

  defp check_state(_params, _pending), do: {:error, "state_mismatch"}

  defp fetch_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp fetch_code(_params), do: {:error, "missing_code"}

  defp exchange(code, pending) do
    case OIDC.exchange_code(code, pending.code_verifier) do
      {:ok, id_token} -> {:ok, id_token}
      {:error, :token_endpoint_unreachable} -> {:error, "token_endpoint_unreachable"}
      {:error, _status_or_no_token} -> {:error, "token_exchange_failed"}
    end
  end

  defp verify(id_token, pending) do
    case OIDC.verify_id_token(id_token, pending.nonce) do
      {:ok, claims} -> {:ok, claims}
      {:error, why} -> {:error, "invalid_id_token:" <> Atom.to_string(why)}
    end
  end

  defp check_group(claims) do
    if OIDC.authorized?(claims), do: :ok, else: {:denied, claims}
  end

  # --- outcomes ---------------------------------------------------------------

  defp sign_in(conn, claims, return_to) do
    auth = claims |> OIDC.user() |> Session.new(System.system_time(:second))
    :ok = SessionRegistry.register(SessionCheck.attrs(auth))

    Audit.emit(:sign_in,
      user: Session.audit_user(auth),
      tenant: Scope.tenant_namespace(),
      source_ip: Audit.Source.from_conn(conn)
    )

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:auth, auth)
    |> put_session(:live_socket_id, Session.live_socket_id(auth))
    |> redirect(to: return_to || ~p"/")
  end

  defp fail(conn, reason) do
    audit_failure(conn, "anonymous", reason)

    conn
    |> put_status(:bad_request)
    |> render(:failure)
  end

  defp deny(conn, claims) do
    user = claims |> OIDC.user() |> Session.audit_user()
    audit_failure(conn, user, "not_in_authorized_group")

    conn
    |> put_status(:forbidden)
    |> render(:denied)
  end

  defp audit_failure(conn, user, reason) do
    Audit.emit(:auth_failure,
      user: user,
      tenant: Scope.tenant_namespace(),
      source_ip: Audit.Source.from_conn(conn),
      reason: reason
    )
  end

  defp require_sign_in_enabled(conn, _opts) do
    if Provider.configured() == Nucleus.Scope.Provider.Cognito do
      conn
    else
      conn |> redirect(to: ~p"/") |> halt()
    end
  end
end
