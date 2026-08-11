defmodule Nucleus.Audit.Sink do
  @moduledoc """
  Where an already-encoded audit record goes.

  `Nucleus.Audit.emit/2` calls `write/1` once per record, synchronously, in
  the caller's process, after serialisation — never before, and never
  rescued. AUD-A07 (writes do not silently fail) holds because a raise here
  propagates all the way to the caller of `emit/2`, not because a sink
  happens to be reliable.

  Two implementations exist:

  - `Nucleus.Audit.Sink.Device` — the default, writes to a configured IO
    device (`:stderr` unless overridden).
  - `Nucleus.Audit.Sink.Test` — configured in `config/test.exs`, delivers the
    record to a registered test process instead of a real device.
  """

  @doc """
  Writes one encoded record. `iodata` is already the fully-formatted record
  (JSON or text, per `Nucleus.Audit.Format`) — a sink's only job is to get it
  to its destination.
  """
  @callback write(iodata()) :: :ok
end
