defmodule Nucleus.Audit.SourceTest do
  use ExUnit.Case, async: true

  alias Nucleus.Audit.Source

  describe "from_conn/1" do
    @tag :unit
    test "chooses the first entry of a multi-hop X-Forwarded-For" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_req_header("x-forwarded-for", "198.51.100.1, 10.0.0.1, 10.0.0.2")

      assert Source.from_conn(conn) == "198.51.100.1"
    end

    @tag :unit
    test "trims whitespace around the first entry" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_req_header("x-forwarded-for", "  198.51.100.1 , 10.0.0.1")

      assert Source.from_conn(conn) == "198.51.100.1"
    end

    @tag :unit
    test "falls back to the peer address when the header is absent" do
      conn = Plug.Test.conn(:get, "/")

      assert Source.from_conn(conn) == "127.0.0.1"
    end

    @tag :unit
    test "falls back to the peer address when the header is empty" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.put_req_header("x-forwarded-for", "")

      assert Source.from_conn(conn) == "127.0.0.1"
    end

    @tag :unit
    test "a malformed header yields nil rather than raising" do
      # A bare conn has no adapter, so get_peer_data/1 itself raises — from_conn
      # must catch that and return nil instead of crashing the caller.
      conn = %Plug.Conn{req_headers: [{"x-forwarded-for", ""}]}

      assert Source.from_conn(conn) == nil
    end
  end
end
