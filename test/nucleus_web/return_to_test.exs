defmodule NucleusWeb.ReturnToTest do
  use ExUnit.Case, async: true

  alias NucleusWeb.ReturnTo

  doctest NucleusWeb.ReturnTo

  @moduletag :unit
  @moduletag action: "AUTH-A03"

  describe "sanitize/1 accepts only a path on this site" do
    test "plain paths, with query strings" do
      assert ReturnTo.sanitize("/") == "/"
      assert ReturnTo.sanitize("/applications") == "/applications"

      assert ReturnTo.sanitize("/environments/prod/secrets?x=1&y=2") ==
               "/environments/prod/secrets?x=1&y=2"
    end

    test "rejects anything that could leave the site" do
      for bad <- [
            "//evil.example.com",
            "///evil.example.com",
            "http://evil.example.com",
            "https://evil.example.com/path",
            "javascript:alert(1)",
            "evil.example.com",
            "/\\evil.example.com",
            "/ok\\path",
            "/\tevil",
            "/a\nb",
            "/a\rb",
            "",
            nil,
            123,
            %{}
          ] do
        assert ReturnTo.sanitize(bad) == nil, "expected #{inspect(bad)} to be rejected"
      end
    end

    test "rejects an over-long value" do
      assert ReturnTo.sanitize("/" <> String.duplicate("a", 2048)) == nil
    end

    test "rejects the auth routes themselves, which would loop" do
      for bad <- [
            "/sign-in",
            "/sign-in?return_to=%2F",
            "/auth/callback",
            "/auth/callback?code=x",
            "/logout"
          ] do
        assert ReturnTo.sanitize(bad) == nil, "expected #{inspect(bad)} to be rejected"
      end

      # ...but a path that merely starts with the same letters is fine.
      assert ReturnTo.sanitize("/sign-in-guide") == "/sign-in-guide"
      assert ReturnTo.sanitize("/authors") == "/authors"
    end
  end

  describe "from_conn/1" do
    test "is the path and query of a GET" do
      conn = Plug.Test.conn(:get, "/environments/prod/secrets?tab=a")
      assert ReturnTo.from_conn(conn) == "/environments/prod/secrets?tab=a"
    end

    test "is just the path when there is no query" do
      assert ReturnTo.from_conn(Plug.Test.conn(:get, "/applications")) == "/applications"
    end

    test "is nil for anything but a GET, which a redirect cannot replay" do
      assert ReturnTo.from_conn(Plug.Test.conn(:post, "/applications")) == nil
      assert ReturnTo.from_conn(Plug.Test.conn(:delete, "/logout")) == nil
    end
  end

  test "sign_in_path/1 encodes the target" do
    assert ReturnTo.sign_in_path("/a?b=c") == "/sign-in?return_to=%2Fa%3Fb%3Dc"
  end
end
