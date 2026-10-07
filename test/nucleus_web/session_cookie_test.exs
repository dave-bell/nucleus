defmodule NucleusWeb.SessionCookieTest do
  use NucleusWeb.AuthCase

  alias Nucleus.Auth.Session

  @cookie "_nucleus_key"
  # Browsers keep a cookie only up to 4096 bytes; leave headroom for the attributes.
  @cookie_budget 3_500

  # Every dot-separated segment of the cookie, decoded the way a curious user
  # (or anyone holding a copy) would try.
  defp readable_parts(value) do
    value
    |> String.split(".")
    |> Enum.flat_map(fn part ->
      case Base.url_decode64(part, padding: false) do
        {:ok, decoded} -> [decoded]
        :error -> []
      end
    end)
  end

  defp signed_in_cookie(conn) do
    {conn, sent} = begin_sign_in(conn)
    key = generate_key("cookie-key")
    stub_cognito(keys: [key], token: {:ok, id_token(key, sent.nonce)})

    conn = conn |> recycle() |> get(~p"/auth/callback", %{"code" => "c", "state" => sent.state})
    {conn, conn.resp_cookies[@cookie]}
  end

  @tag action: "AUTH-A02"
  test "the session cookie does not reveal who is signed in", %{conn: conn} do
    {_conn, cookie} = signed_in_cookie(conn)

    refute cookie.value =~ "ada@example.com"
    refute Enum.any?(readable_parts(cookie.value), &String.contains?(&1, "ada@example.com"))
  end

  @tag action: "AUTH-A02"
  test "the PKCE verifier in the cookie during sign-in cannot be read from it", %{conn: conn} do
    {conn, sent} = begin_sign_in(conn)
    verifier = get_session(conn, :auth_pending).code_verifier
    cookie = conn.resp_cookies[@cookie]

    refute cookie.value =~ verifier
    refute Enum.any?(readable_parts(cookie.value), &String.contains?(&1, verifier))
    refute Enum.any?(readable_parts(cookie.value), &String.contains?(&1, sent.state))
  end

  @tag action: "AUTH-A02"
  test "an encrypted cookie still round-trips: the server reads its own session back", %{
    conn: conn
  } do
    {conn, _cookie} = signed_in_cookie(conn)

    conn = conn |> recycle() |> get(~p"/")

    assert conn.status == 200
    assert conn.assigns.current_scope.user.email == "ada@example.com"
  end

  @tag action: "AUTH-A06"
  test "a cookie encrypted for another key is no session at all", %{conn: conn} do
    {_conn, cookie} = signed_in_cookie(conn)
    tampered = String.slice(cookie.value, 0..-6//1) <> "AAAAA"

    conn = build_conn() |> put_req_cookie(@cookie, tampered) |> get(~p"/")

    assert redirected_to(conn) == "/sign-in?return_to=%2F"
    assert audit_events() |> Enum.filter(&(&1.event == :sign_out)) == []
  end

  @tag action: "AUTH-A02"
  test "a signed-in session fits comfortably in a cookie", %{conn: conn} do
    {_conn, cookie} = signed_in_cookie(conn)
    assert byte_size(cookie.value) < @cookie_budget
  end

  @tag action: "AUTH-A02"
  test "a sign-in in flight fits too", %{conn: conn} do
    {conn, _sent} = begin_sign_in(conn, %{"return_to" => "/" <> String.duplicate("a", 1500)})
    assert byte_size(conn.resp_cookies[@cookie].value) < @cookie_budget
  end

  test "the cookie is HttpOnly and SameSite=Lax (Lax is what lets it survive the redirect back from Cognito)",
       %{conn: conn} do
    {_conn, cookie} = signed_in_cookie(conn)

    # Plug sends HttpOnly unless a cookie opts out, so absent means on.
    assert Map.get(cookie, :http_only, true)
    assert cookie.same_site == "Lax"
  end

  test "the cookie holds the session struct and no token", %{conn: conn} do
    {conn, _cookie} = signed_in_cookie(conn)
    assert %Session{} = get_session(conn, :auth)
    refute inspect(get_session(conn)) =~ "must-never-be-kept"
  end
end
