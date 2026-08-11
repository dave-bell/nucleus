defmodule Nucleus.Audit do
  @moduledoc """
  The single entry point for writing a compliance audit record.

  Bypasses `Logger` entirely — see `docs/adr/0004-audit-emission.md` for why.
  `emit/2` validates against the catalogue in `Nucleus.Audit.Event`, stamps
  its own timestamp, formats via `Nucleus.Audit.Format`, and writes via the
  configured `Nucleus.Audit.Sink`, synchronously, in the caller's process.

  Configure via `config :nucleus, Nucleus.Audit, sink:, format:, device:` —
  see `config/config.exs`, `config/dev.exs`, `config/test.exs`, and
  `config/runtime.exs`.
  """

  alias Nucleus.Audit.{Event, Format}

  @doc """
  Emits one audit record for `event`, built from `fields`.

  `fields` is a keyword list of the `Nucleus.Audit.Event` struct fields this
  event accepts — see `Nucleus.Audit.Event.spec/1` for the per-event allowed
  and required lists. Notably:

  - `:timestamp` is never accepted here — it is always stamped with
    `DateTime.utc_now/0`, so a caller cannot backdate or forge a record.
  - `:user` defaults to `"anonymous"` when absent.
  - `:details` (when the event allows it) is itself key-allowlisted per
    event — an unlisted key inside `details` raises exactly like an unlisted
    top-level key.

  Raises `ArgumentError` for: an unknown event, an unlisted field or detail
  key (this is the AUD-A02 defence — there is no `value` key to pass), or a
  missing required field. Never rescues a raise from the underlying sink —
  a silently-failing audit emitter is worse than a crash, because it looks
  compliant (AUD-A07).
  """
  @spec emit(Event.event(), keyword()) :: :ok
  def emit(event, fields \\ []) when is_atom(event) and is_list(fields) do
    unless Event.known?(event) do
      raise ArgumentError,
            "unknown audit event #{inspect(event)}. Known events: #{inspect(Event.events())}"
    end

    spec = Event.spec(event)
    details = Keyword.get(fields, :details, %{})

    validate_top_level!(event, fields, spec)
    validate_details!(event, details, spec)
    validate_required!(event, fields, details, spec)

    record = %Event{
      event: event,
      user: Keyword.get(fields, :user) || "anonymous",
      tenant: Keyword.get(fields, :tenant),
      timestamp: DateTime.utc_now(),
      source_ip: Keyword.get(fields, :source_ip),
      resource: Keyword.get(fields, :resource),
      reason: Keyword.get(fields, :reason),
      details: details
    }

    format = Keyword.fetch!(config(), :format)
    sink = Keyword.fetch!(config(), :sink)

    record
    |> Format.encode(format)
    |> sink.write()

    :ok
  end

  defp validate_top_level!(event, fields, spec) do
    allowed = MapSet.new([:user | spec.allowed])

    case Enum.find(fields, fn {key, _value} -> not MapSet.member?(allowed, key) end) do
      nil ->
        :ok

      {key, _value} ->
        raise ArgumentError,
              "unknown field #{inspect(key)} for audit event #{inspect(event)}. " <>
                "Allowed fields: #{inspect(MapSet.to_list(allowed))}"
    end
  end

  defp validate_details!(_event, details, _spec) when details == %{}, do: :ok

  defp validate_details!(event, details, spec) when is_map(details) do
    allowed = MapSet.new(spec.details_allowed)

    case Enum.find(details, fn {key, _value} -> not MapSet.member?(allowed, key) end) do
      nil ->
        :ok

      {key, _value} ->
        raise ArgumentError,
              "unknown detail #{inspect(key)} for audit event #{inspect(event)}. " <>
                "Allowed details: #{inspect(spec.details_allowed)}"
    end
  end

  defp validate_details!(event, other, _spec) do
    raise ArgumentError,
          "details for audit event #{inspect(event)} must be a map, got: #{inspect(other)}"
  end

  defp validate_required!(event, fields, details, spec) do
    missing_top = Enum.filter(spec.required, &is_nil(Keyword.get(fields, &1)))
    missing_details = Enum.filter(spec.details_required, &is_nil(Map.get(details, &1)))

    case missing_top ++ missing_details do
      [] ->
        :ok

      missing ->
        raise ArgumentError,
              "audit event #{inspect(event)} is missing required field(s): #{inspect(missing)}"
    end
  end

  defp config, do: Application.fetch_env!(:nucleus, __MODULE__)
end
