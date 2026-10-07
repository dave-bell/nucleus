defmodule Nucleus.Auth.SessionCheck do
  @moduledoc """
  The one answer to "is this browser's session still valid?" (`AUTH-A05`,
  `AUTH-A06`, `AUTH-A08`).

  Called from exactly two places - `NucleusWeb.Plugs.AssignScope` for HTTP
  requests and `NucleusWeb.AuthHook` for LiveView mounts and reconnects - so
  the two cannot drift. It is *not* called per `handle_event`: `AUTH-A05`
  scopes independent re-validation to request and mount granularity.

  ## What it checks, in order

  1. **A session at all.** No `"auth"` key - never signed in, or a cookie that
     failed signature verification or decryption (Plug hands us an empty
     session for both) - is `{:error, :no_session}`. Deliberately unaudited:
     auditing every first visit would flood the log (`AUTH-A06`).
  2. **Max age**, from the cookie's own `signed_in_at`. Needs no server state,
     so it survives a restart.
  3. **The registry's verdict** (`Nucleus.Auth.SessionRegistry`): active,
     expired (idle, max age, or signed out), or terminated.
  4. **A session the registry does not know** - after a restart - falls back to
     the cookie's `last_active` for the idle test and, if still valid, is
     re-registered. That can only err towards signing out early.

  ## Side effects

  Not pure, by design: finding a session expired is also what ends it.
  `SessionRegistry.expire/3` makes that transition atomically, and only the
  caller that wins it emits `sign_out` (`reason=idle|max_age`) and disconnects
  the session's tabs, so a session that several requests discover at once is
  still announced once. A successful check counts as activity.

  ## Result

  - `{:ok, session}` - valid, with `last_active` advanced (write it back to the
    cookie where a cookie can be written)
  - `{:error, :no_session}`
  - `{:error, {:expired, :idle | :max_age | :user}}`
  - `{:error, :terminated}`
  """

  alias Nucleus.Auth.{Config, Session, SessionRegistry}
  alias Nucleus.Scope

  @type result ::
          {:ok, Session.t()}
          | {:error, :no_session}
          | {:error, {:expired, :idle | :max_age | :user}}
          | {:error, :terminated}

  @doc """
  Validates the `"auth"` entry of a session map (a `Plug.Conn` session or the
  session LiveView passes to `on_mount`).

  Options: `:registry` (default `Nucleus.Auth.SessionRegistry`) and `:now`
  (Unix seconds, default the current time).
  """
  @spec validate(map(), keyword()) :: result()
  def validate(session, opts \\ []) when is_map(session) do
    registry = Keyword.get(opts, :registry, SessionRegistry)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

    case Map.get(session, "auth") do
      %Session{} = auth -> check(auth, registry, now)
      _none -> {:error, :no_session}
    end
  end

  defp check(%Session{} = auth, registry, now) do
    if now >= auth.signed_in_at + Config.max_age() do
      end_session(auth, :max_age, registry)
    else
      case SessionRegistry.status(auth.id, registry) do
        :active -> active(auth, registry, now)
        {:expired, reason} -> end_session(auth, reason, registry)
        :terminated -> {:error, :terminated}
        :unknown -> recover(auth, registry, now)
      end
    end
  end

  # The registry has no record: a restart, or a session written by another node.
  defp recover(%Session{} = auth, registry, now) do
    if now >= auth.last_active + Config.idle_timeout() do
      end_session(auth, :idle, registry)
    else
      :ok = SessionRegistry.register(attrs(auth), registry)
      active(auth, registry, now)
    end
  end

  defp active(%Session{} = auth, registry, now) do
    SessionRegistry.touch(auth.id, registry)
    {:ok, Session.touch(auth, now)}
  end

  defp end_session(%Session{} = auth, reason, registry) do
    case SessionRegistry.expire(attrs(auth), reason, registry) do
      {:ok, record} -> SessionRegistry.announce_expiry(record, reason)
      :already -> :ok
    end

    {:error, {:expired, reason}}
  end

  @doc "The registry attributes for `auth` (times in milliseconds)."
  @spec attrs(Session.t()) :: SessionRegistry.attrs()
  def attrs(%Session{} = auth) do
    %{
      id: auth.id,
      user: Session.audit_user(auth),
      tenant: Scope.tenant_namespace(),
      signed_in_at: auth.signed_in_at * 1000,
      last_active: auth.last_active * 1000
    }
  end
end
