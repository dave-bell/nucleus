defmodule NucleusWeb.ScopeHook do
  @moduledoc """
  `on_mount` hook that assigns `current_scope` to every LiveView in a
  `live_session`.

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

  ## Never render `@current_scope` wholesale

  LiveView diffs rendered output, not raw assigns, so a token sitting in
  `socket.assigns.current_scope.token` is never sent to the client on its
  own. That is a constraint on template authors, not an ambient guarantee —
  never write `inspect(@current_scope)`, or any other rendering of the whole
  struct, in a template. `token` is always `nil` for the whole of EN-6, but
  the guard needs to exist before it is ever populated — see
  `docs/adr/0005-deferred-authentication.md`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [get_connect_info: 2]

  alias Nucleus.Scope

  @spec on_mount(:assign, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign, _params, session, socket) do
    scope = scope_from_session(session) || build_scope(socket)

    {:cont, assign(socket, :current_scope, scope)}
  end

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
