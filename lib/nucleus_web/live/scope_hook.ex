defmodule NucleusWeb.ScopeHook do
  @moduledoc """
  `on_mount` hook that authorizes every LiveView mount and assigns
  `current_scope` to every LiveView in a `live_session`.

  Attached via `live_session ..., on_mount: {NucleusWeb.ScopeHook, :assign}`
  (EN-7's router work) so every authenticated LiveView gets it — not
  per-LiveView, which is how one gets forgotten (`AGENTS.md`).

  Prefers the scope `NucleusWeb.Plugs.AssignScope` already put in the
  session — the `source_ip` there was captured from the `Plug.Conn` that no
  longer exists once the socket is live. When the session has no scope (a
  LiveView mounted outside the `:browser` pipeline, or a socket reconnecting
  without one), builds one fresh via `Nucleus.Scope.Provider.build/1`, reading
  `source_ip` from `get_connect_info(socket, :x_headers)` — the only place
  `X-Forwarded-For` is still available once the initial HTTP request is gone.

  ## Authorization (`AUTH_ENABLED=true`)

  With the Cognito provider this hook is the LiveView half of `AUTH-A05`: the
  other half is `NucleusWeb.Plugs.AssignScope` for plain HTTP requests, and
  both ask the same question of `Nucleus.Auth.SessionCheck`. It runs on every
  mount and reconnect - including the remount that a `<.link navigate>`
  between LiveViews causes - and, unlike the disabled-auth path, **it can
  halt**: an invalid session redirects to sign-in before any LiveView's
  `mount/3` runs, so no tenant data is fetched for it.

  It deliberately does **not** check on `handle_event`. `AUTH-A05` scopes the
  guarantee to request and mount granularity, by product decision: no token is
  forwarded anywhere that a per-event check would protect. What the hook does
  attach is two *non-halting* hooks that report activity, so a user busy in one
  page still keeps their session alive:

  - `:handle_params` - every navigation, reporting the path as well, which is
    how `AUTH-A09` knows "the page they were on" when the session later ends;
  - `:handle_event` - clicks, form edits, submits, throttled to one report per
    `Nucleus.Auth.Config.activity_throttle_ms/0` (a text field fires an event
    per keystroke).

  A LiveView cannot write a cookie, which is why activity goes to
  `Nucleus.Auth.SessionRegistry` rather than into the session.

  With `AUTH_ENABLED=false` it behaves as it always has: assigns the dev scope,
  never halts.

  ## Never render `@current_scope` wholesale

  LiveView diffs rendered output, not raw assigns, so nothing in
  `socket.assigns.current_scope` reaches the client unless a template renders
  it. That is a constraint on template authors, not an ambient guarantee —
  never write `inspect(@current_scope)`, or any other rendering of the whole
  struct, in a template. The scope carries no token (`Nucleus.Scope`), but it
  does carry the user's identity and source IP.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, get_connect_info: 2, redirect: 2]

  alias Nucleus.Auth.{Config, Session, SessionCheck, SessionRegistry}
  alias Nucleus.Scope
  alias Nucleus.Scope.Provider
  alias NucleusWeb.ReturnTo

  @spec on_mount(:assign, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign, _params, session, socket) do
    if Provider.configured() == Nucleus.Scope.Provider.Cognito do
      authorize(session, socket)
    else
      scope = scope_from_session(session) || build_scope(socket)
      {:cont, assign(socket, :current_scope, scope)}
    end
  end

  defp authorize(session, socket) do
    case SessionCheck.validate(session) do
      {:ok, %Session{} = auth} ->
        {:ok, scope} =
          Provider.build(%{session: auth, source_ip: source_ip(session, socket)})

        socket =
          socket
          |> assign(:current_scope, scope)
          |> assign(:auth_activity_at, System.monotonic_time(:millisecond))
          |> attach_activity_hooks(auth.id)

        {:cont, socket}

      {:error, _no_valid_session} ->
        {:halt, redirect(socket, to: sign_in_path(session))}
    end
  end

  # Back to the page the session was last seen on (AUTH-A09), which only the
  # registry knows - a mount is not told the page URL. A visitor who never had
  # a session has nowhere to be sent back to.
  defp sign_in_path(%{"auth" => %Session{id: id}}) do
    id |> SessionRegistry.last_path() |> ReturnTo.sign_in_path()
  end

  defp sign_in_path(_session), do: ReturnTo.sign_in_path(nil)

  defp attach_activity_hooks(socket, session_id) do
    if connected?(socket) do
      socket
      |> attach_navigation_hook(session_id)
      |> attach_hook(:auth_activity, :handle_event, fn _event, _params, socket ->
        {:cont, report_activity(socket, session_id)}
      end)
    else
      socket
    end
  end

  # `handle_params` hooks exist only for a LiveView mounted at the router;
  # an isolated one (a test's `live_isolated/2`) has no navigation to report.
  defp attach_navigation_hook(%{router: nil} = socket, _session_id), do: socket

  defp attach_navigation_hook(socket, session_id) do
    attach_hook(socket, :auth_navigation, :handle_params, fn _params, uri, socket ->
      SessionRegistry.touch(session_id, path_of(uri))
      {:cont, socket}
    end)
  end

  defp report_activity(socket, session_id) do
    now = System.monotonic_time(:millisecond)

    if now - socket.assigns.auth_activity_at >= Config.activity_throttle_ms() do
      SessionRegistry.touch(session_id)
      assign(socket, :auth_activity_at, now)
    else
      socket
    end
  end

  defp path_of(uri) do
    %URI{path: path, query: query} = URI.parse(uri)
    ReturnTo.sanitize(if query in [nil, ""], do: path, else: path <> "?" <> query)
  end

  defp source_ip(%{"current_scope" => %Scope{source_ip: ip}}, _socket) when is_binary(ip), do: ip
  defp source_ip(_session, socket), do: source_ip_from_connect_info(socket)

  defp scope_from_session(%{"current_scope" => %Scope{} = scope}), do: scope
  defp scope_from_session(_session), do: nil

  defp build_scope(socket) do
    {:ok, scope} = Scope.Provider.build(%{source_ip: source_ip_from_connect_info(socket)})
    scope
  end

  # Mirrors Nucleus.Audit.Source.from_conn/1's algorithm — first
  # X-Forwarded-For entry — re-derived for the socket's :x_headers instead of
  # a Plug.Conn, since that is all that remains once the socket is live.
  defp source_ip_from_connect_info(socket) do
    with headers when is_list(headers) <- get_connect_info(socket, :x_headers),
         {_key, value} <- List.keyfind(headers, "x-forwarded-for", 0),
         [first | _] <- String.split(value, ","),
         trimmed <- String.trim(first),
         true <- trimmed != "" do
      trimmed
    else
      _ -> nil
    end
  end
end
