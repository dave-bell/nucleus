defmodule Nucleus.Audit.Sink.Raising do
  @moduledoc """
  A `Nucleus.Audit.Sink` that always raises, for asserting AUD-A07 — that a
  sink failure propagates out of `Nucleus.Audit.emit/2` instead of being
  swallowed into a silent no-op.
  """

  @behaviour Nucleus.Audit.Sink

  @impl Nucleus.Audit.Sink
  def write(_iodata) do
    raise "boom: the sink is down"
  end
end
