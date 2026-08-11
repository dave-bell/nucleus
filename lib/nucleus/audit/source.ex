defmodule Nucleus.Audit.Source do
  @moduledoc """
  Extracts the caller's source IP for an audit record from a `Plug.Conn`.

  Per the wiki's [ADR-0003](https://github.com/dave-bell/nucleus/wiki/ADR-0003-Compliance-Audit-Logging)
  (reference-only prior art — re-derived here for `Plug.Conn` rather than
  inherited): prefer the **first** entry of `X-Forwarded-For` — the original
  client, closest to the browser, as opposed to any intermediate proxy — and
  fall back to the direct peer address for connections with nothing in front
  of them (health checks, local dev).

  A malformed or empty header never raises; it falls through to the peer
  address, and if that is unavailable too, this returns `nil`. A source IP is
  useful audit context, not a value anything should crash over.
  """

  @spec from_conn(Plug.Conn.t()) :: String.t() | nil
  def from_conn(%Plug.Conn{} = conn) do
    do_from_conn(conn)
  rescue
    _ -> nil
  end

  defp do_from_conn(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [value | _] -> first_entry(value) || peer(conn)
      [] -> peer(conn)
    end
  end

  defp first_entry(value) do
    value
    |> String.split(",")
    |> List.first("")
    |> String.trim()
    |> case do
      "" -> nil
      entry -> entry
    end
  end

  defp peer(conn) do
    case Plug.Conn.get_peer_data(conn) do
      %{address: address} -> address |> :inet.ntoa() |> to_string()
      _ -> nil
    end
  end
end
