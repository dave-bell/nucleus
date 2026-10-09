defmodule NucleusWeb.AuthCase do
  @moduledoc """
  The composed case for tests that run with real sign-in turned on
  (`AUTH_ENABLED=true`): `NucleusWeb.ConnCase`, `Nucleus.AuditCase`, the
  Cognito scope provider, a full set of sign-in settings with a stubbed Cognito
  (`Nucleus.AuthFixtures`), and one RSA signing key.

  Mutates global application env, so always `async: false`. Everything is
  restored on exit.

  ## Helpers

  - `sign_in_session/2` - a conn carrying a valid signed-in session, registered
    with the session registry, as the callback would have left it
  - `begin_sign_in/2` - runs `POST /sign-in` and returns the conn plus the
    `state` and `nonce` Nucleus sent to the Hosted UI
  - `id_token/3` - a token signed by the suite's key
  """

  use ExUnit.CaseTemplate

  alias Nucleus.Auth.{Session, SessionCheck, SessionRegistry}

  using do
    quote do
      use NucleusWeb.ConnCase, async: false
      use Nucleus.AuditCase, async: false

      import Nucleus.AuthFixtures
      import NucleusWeb.AuthCase
    end
  end

  setup do
    previous = Application.get_env(:nucleus, Nucleus.Scope)

    Application.put_env(
      :nucleus,
      Nucleus.Scope,
      Keyword.put(previous || [], :provider, Nucleus.Scope.Provider.Cognito)
    )

    on_exit(fn -> Application.put_env(:nucleus, Nucleus.Scope, previous) end)

    Nucleus.AuthFixtures.put_auth_config()
    {:ok, key: Nucleus.AuthFixtures.generate_key("suite-key")}
  end

  @doc """
  `conn` with a valid signed-in session, registered with the session registry.

  Options: `:email`, `:username`, `:signed_in_at`, `:last_active` (Unix
  seconds; default now), `:register` (default `true`). Returns
  `{conn, %Nucleus.Auth.Session{}}`.
  """
  def sign_in_session(conn, opts \\ []) do
    now = System.system_time(:second)

    session = %Session{
      id: Keyword.get(opts, :id, "sid-#{System.unique_integer([:positive])}"),
      email: Keyword.get(opts, :email, "ada@example.com"),
      username: Keyword.get(opts, :username, "ada"),
      signed_in_at: Keyword.get(opts, :signed_in_at, now),
      last_active: Keyword.get(opts, :last_active, Keyword.get(opts, :signed_in_at, now))
    }

    if Keyword.get(opts, :register, true) do
      :ok = SessionRegistry.register(SessionCheck.attrs(session))
    end

    conn =
      Plug.Test.init_test_session(conn, %{
        auth: session,
        live_socket_id: Session.live_socket_id(session)
      })

    {conn, session}
  end

  @doc "Runs `POST /sign-in`; returns `{conn, %{state:, nonce:, url:}}`."
  def begin_sign_in(conn, params \\ %{}) do
    conn = Phoenix.ConnTest.dispatch(conn, NucleusWeb.Endpoint, :post, "/sign-in", params)
    url = Phoenix.ConnTest.redirected_to(conn, 302)
    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    {conn, %{state: query["state"], nonce: query["nonce"], url: url, query: query}}
  end

  @doc "An ID token signed with `key`, valid unless `overrides` say otherwise."
  def id_token(key, nonce, overrides \\ %{}) do
    Nucleus.AuthFixtures.sign(
      key,
      Nucleus.AuthFixtures.claims(Map.put(overrides, "nonce", nonce))
    )
  end
end
