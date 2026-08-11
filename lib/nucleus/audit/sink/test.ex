defmodule Nucleus.Audit.Sink.Test do
  @moduledoc """
  Delivers each encoded audit record to a registered test process instead of
  a real IO device. Configured as the sink in `config/test.exs`.

  `Nucleus.Audit.emit/2` runs entirely in the calling process and writes
  synchronously (AUD-A07), so `register/1` stores the receiving pid in the
  *calling* process's dictionary — safe under `async: true`, since no other
  test's process shares it.

  EN-8's `AuditCase` and its `refute_audit_contains/1` helper are built on
  this module.
  """

  @behaviour Nucleus.Audit.Sink

  @key :nucleus_audit_test_pid

  @doc """
  Registers `pid` (default `self()`) to receive `{:audit, binary}` messages
  for every record `Nucleus.Audit.emit/2` writes from the current process.
  """
  @spec register(pid()) :: :ok
  def register(pid \\ self()) do
    Process.put(@key, pid)
    :ok
  end

  @impl Nucleus.Audit.Sink
  def write(iodata) do
    case Process.get(@key) do
      nil ->
        raise "Nucleus.Audit.Sink.Test has no registered process — call " <>
                "Nucleus.Audit.Sink.Test.register/1 before emitting an audit event in a test"

      pid ->
        send(pid, {:audit, IO.iodata_to_binary(iodata)})
        :ok
    end
  end
end
