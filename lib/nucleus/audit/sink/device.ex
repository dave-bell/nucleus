defmodule Nucleus.Audit.Sink.Device do
  @moduledoc """
  Writes each audit record synchronously to a configured IO device.

  Default device is `:stderr`, distinct from `Logger`'s default of
  `:stdio` (standard output) — this is AUD-A06 (a separate stream from
  application logs) satisfied for free by the runtime, with no
  application-level routing. Override with `AUDIT_DEVICE` (see
  `config/runtime.exs`) to point at standard output, a file, or any other
  IO device (a `pid`, e.g. a `StringIO` process — useful for tests that want
  to assert on the exact bytes written).

  `IO.write/2` to a device is synchronous, which is what AUD-A07 requires:
  the write completes before this function returns, and this module raises
  rather than rescuing if the underlying device write fails.
  """

  @behaviour Nucleus.Audit.Sink

  @impl Nucleus.Audit.Sink
  def write(iodata) do
    IO.write(device(), iodata)
    :ok
  end

  @doc """
  Casts an `AUDIT_DEVICE` name (`"stdout"` or `"stderr"`) to the IO device
  atom Erlang recognises.

  There is no `:stdout` IO device in Erlang/Elixir — standard output is
  `:stdio` — so `config/runtime.exs` must not pass the env var's literal
  string through as an atom. Returns `:error` for anything else, which
  `config/runtime.exs` treats as a file path to open instead.

      iex> Nucleus.Audit.Sink.Device.cast_device_name("stdout")
      {:ok, :stdio}

      iex> Nucleus.Audit.Sink.Device.cast_device_name("stderr")
      {:ok, :stderr}

      iex> Nucleus.Audit.Sink.Device.cast_device_name("/var/log/audit.log")
      :error
  """
  @spec cast_device_name(String.t()) :: {:ok, atom()} | :error
  def cast_device_name("stdout"), do: {:ok, :stdio}
  def cast_device_name("stderr"), do: {:ok, :stderr}
  def cast_device_name(_other), do: :error

  defp device do
    :nucleus
    |> Application.get_env(Nucleus.Audit, [])
    |> Keyword.get(:device, :stderr)
  end
end
