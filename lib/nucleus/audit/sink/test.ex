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

  ## Falling back to `$callers` (`SEC-S4`)

  Every audit call before `SEC-S4` ran directly in the test process (a
  context function called straight from a `test` block), so `register/1`
  having been called there was always enough. `SEC-S4` is the first ticket
  to emit from *inside* a mounted LiveView — a distinct GenServer process a
  test never calls `register/1` from directly. Rather than have every such
  test reach into the view process to register itself (there is no public
  API to run code there), `write/1` falls back to `Process.get(:"$callers")`
  when the writing process has no direct registration of its own.
  `Phoenix.LiveViewTest` sets `$callers` on the spawned view process to the
  test process that mounted it — the same ancestry Ecto's SQL Sandbox relies
  on for its own process-allowance mechanism — so the fallback reaches
  exactly the process that already called `register/1` in its `AuditCase`
  `setup`, with no LiveView code aware that a test is watching.
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
    case receiver() do
      nil ->
        raise "Nucleus.Audit.Sink.Test has no registered process — call " <>
                "Nucleus.Audit.Sink.Test.register/1 before emitting an audit event in a test"

      pid ->
        send(pid, {:audit, IO.iodata_to_binary(iodata)})
        :ok
    end
  end

  defp receiver do
    case Process.get(@key) do
      nil ->
        case Process.get(:"$callers") do
          [pid | _] -> pid
          _no_callers -> nil
        end

      pid ->
        pid
    end
  end
end
