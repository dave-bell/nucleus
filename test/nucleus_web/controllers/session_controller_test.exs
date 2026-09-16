defmodule NucleusWeb.SessionControllerTest do
  use NucleusWeb.ConnCase, async: true

  describe "NAV-A08 — DELETE /logout" do
    @tag action: "NAV-A08"
    test "drops the session cookie and redirects to /", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert get_session(conn, :current_scope)

      conn = conn |> recycle() |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/"

      # `configure_session(drop: true)` deletes the session cookie in the
      # response rather than clearing the already-decoded session map on
      # this same conn — Plug only acts on the drop at `before_send`
      # (`deps/plug/lib/plug/session.ex`), so the observable proof here is
      # the deleted response cookie, not `get_session/2` on this struct.
      assert %{max_age: 0} = conn.resp_cookies["_nucleus_key"]
    end

    @tag action: "NAV-A08"
    test "a fresh request after logout resets nav_session_id but is re-identified as the same dev scope",
         %{conn: conn} do
      conn = get(conn, ~p"/")
      nav_session_id_before = get_session(conn, :nav_session_id)
      assert nav_session_id_before

      conn =
        conn
        |> recycle()
        |> delete(~p"/logout")
        |> recycle()
        |> get(~p"/")

      # There is no real session to have ended (deferred authentication,
      # `docs/adr/0005-deferred-authentication.md`; `current_scope.token`
      # is unconditionally `nil`) — the next request is immediately
      # re-identified as the same dev user. What genuinely changed is
      # `nav_session_id` (NAV-A05's sidebar expand state key), because the
      # session it lived in was dropped.
      assert get_session(conn, :current_scope)
      assert get_session(conn, :nav_session_id)
      assert get_session(conn, :nav_session_id) != nav_session_id_before
    end
  end
end
