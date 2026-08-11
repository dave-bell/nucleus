defmodule Nucleus.Audit.Format do
  @moduledoc """
  Serialises a `%Nucleus.Audit.Event{}` for a sink.

  Two formats, selected strictly downstream of every decision about whether
  and what to record — `Nucleus.Audit.emit/2` builds the full `Event` struct
  first, and formatting never adds, drops, or renames a field. AUD-A05
  requires the *set* of recorded fields to be identical across formats; only
  the encoding differs.

  - `:json` — the default, and required in any deployed environment. One
    record per line, newline-terminated, `Jason`-encoded. `event` is a
    string, `timestamp` is ISO 8601 UTC.
  - `:text` — the dev default. A single human-readable line. Values are
    quoted and escaped so a `%` or `{}` in a resource path cannot be
    mistaken for a field delimiter.
  """

  alias Nucleus.Audit.Event

  @type format :: :json | :text

  @top_level_fields [:event, :user, :tenant, :timestamp, :source_ip, :resource, :reason]

  @doc """
  Encodes `event` as `format`, returning iodata ready for a sink.
  """
  @spec encode(Event.t(), format()) :: iodata()
  def encode(%Event{} = event, :json), do: encode_json(event)
  def encode(%Event{} = event, :text), do: encode_text(event)

  @doc """
  Casts an `AUDIT_FORMAT` value (`"json"` or `"text"`) to a `format()`.

  Returns `:error` for anything else so `config/runtime.exs` can raise with
  the offending value rather than silently falling back to a default — a
  typo here should not silently change what a compliance pipeline receives.

      iex> Nucleus.Audit.Format.cast("json")
      {:ok, :json}

      iex> Nucleus.Audit.Format.cast("bogus")
      :error
  """
  @spec cast(String.t()) :: {:ok, format()} | :error
  def cast("json"), do: {:ok, :json}
  def cast("text"), do: {:ok, :text}
  def cast(_other), do: :error

  defp encode_json(event) do
    map = %{
      event: Atom.to_string(event.event),
      user: event.user,
      tenant: event.tenant,
      timestamp: DateTime.to_iso8601(event.timestamp),
      source_ip: event.source_ip,
      resource: event.resource,
      reason: event.reason,
      details: event.details
    }

    [Jason.encode!(map), "\n"]
  end

  defp encode_text(event) do
    # Every top-level field is always printed, even when nil (as `key=""`).
    # AUD-A05 requires the recorded field *set* to be identical across
    # formats — `:json` always carries every key (nil as `null`), so
    # dropping a nil field here instead of the caller (e.g. `secret_viewed`,
    # which never has a `reason` or `source_ip`) would make the two formats
    # disagree about what was recorded for the exact events this ticket
    # wires up.
    top_level = Enum.map(@top_level_fields, &{&1, top_level_value(event, &1)})

    details = Enum.map(event.details, fn {key, value} -> {key, value} end)

    (top_level ++ details)
    |> Enum.map(fn {key, value} -> "#{key}=#{quote_value(value)}" end)
    |> Enum.join(" ")
    |> then(&[&1, "\n"])
  end

  defp top_level_value(event, :event), do: Atom.to_string(event.event)
  defp top_level_value(event, :timestamp), do: DateTime.to_iso8601(event.timestamp)
  defp top_level_value(event, key), do: Map.fetch!(Map.from_struct(event), key)

  defp quote_value(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")

    "\"#{escaped}\""
  end
end
