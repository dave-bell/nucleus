defmodule NucleusWeb.ReturnTo do
  @moduledoc """
  The "send me back where I was" path carried through sign-in (`AUTH-A03`,
  `AUTH-A09`, `NAV-A10`).

  It travels as `?return_to=` on the sign-in URL, through the sign-in form, and
  the session, and is finally redirected to - so it is attacker-controlled input
  headed for `redirect/2`. `sanitize/1` accepts only an absolute *path* on this
  site, and answers `nil` for anything else, so a crafted link cannot turn the
  sign-in page into an open redirect.

  Rejected: anything not starting with a single `/` (a bare host, `//host`,
  `http://...`, `javascript:`), any backslash (browsers treat `/\\host` as
  `//host`), control characters (a tab or newline can be stripped by a browser
  into something that parses differently), over-long values, and the auth
  routes themselves (returning to `/sign-in` after signing in would loop).
  """

  @max_bytes 2048
  @auth_routes ["/sign-in", "/auth", "/logout"]

  @doc """
  The sanitized path, or `nil`.

      iex> NucleusWeb.ReturnTo.sanitize("/environments/prod/secrets?tab=a")
      "/environments/prod/secrets?tab=a"

      iex> NucleusWeb.ReturnTo.sanitize("//evil.example.com")
      nil

      iex> NucleusWeb.ReturnTo.sanitize("https://evil.example.com")
      nil

      iex> NucleusWeb.ReturnTo.sanitize("/\\\\evil.example.com")
      nil

      iex> NucleusWeb.ReturnTo.sanitize("/sign-in")
      nil
  """
  @spec sanitize(term()) :: String.t() | nil
  def sanitize(path) when is_binary(path) and byte_size(path) <= @max_bytes do
    with "/" <> rest <- path,
         false <- String.starts_with?(rest, "/"),
         false <- String.contains?(path, "\\"),
         false <- control_chars?(path),
         false <- auth_route?(path),
         %URI{scheme: nil, host: nil} <- URI.parse(path) do
      path
    else
      _ -> nil
    end
  end

  def sanitize(_other), do: nil

  @doc """
  The sign-in URL, carrying `path` (sanitized) as `return_to` when it is a
  valid return target.

      iex> NucleusWeb.ReturnTo.sign_in_path("/applications")
      "/sign-in?return_to=%2Fapplications"

      iex> NucleusWeb.ReturnTo.sign_in_path(nil)
      "/sign-in"

      iex> NucleusWeb.ReturnTo.sign_in_path("//evil.example.com")
      "/sign-in"
  """
  @spec sign_in_path(term()) :: String.t()
  def sign_in_path(path) do
    case sanitize(path) do
      nil -> "/sign-in"
      safe -> "/sign-in?" <> URI.encode_query(return_to: safe)
    end
  end

  @doc "The request's own path and query - what to come back to - for a `Plug.Conn`."
  @spec from_conn(Plug.Conn.t()) :: String.t() | nil
  def from_conn(%Plug.Conn{method: "GET"} = conn) do
    case conn.query_string do
      "" -> conn.request_path
      query -> conn.request_path <> "?" <> query
    end
  end

  # Only a GET can be replayed by a redirect; returning to a POST/DELETE path
  # would turn into a GET of something that was never meant to be one.
  def from_conn(%Plug.Conn{}), do: nil

  defp control_chars?(path), do: String.match?(path, ~r/[\x00-\x1f\x7f]/)

  defp auth_route?(path) do
    [route | _] = String.split(path, ["?", "#"], parts: 2)
    Enum.any?(@auth_routes, &(route == &1 or String.starts_with?(route, &1 <> "/")))
  end
end
