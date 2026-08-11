defmodule Nucleus.Audit.Sink.DeviceTest do
  # Mutates :nucleus, Nucleus.Audit application config, which is global.
  use ExUnit.Case, async: false

  alias Nucleus.Audit.Sink.Device

  doctest Device

  setup do
    original = Application.fetch_env!(:nucleus, Nucleus.Audit)
    on_exit(fn -> Application.put_env(:nucleus, Nucleus.Audit, original) end)
    {:ok, original: original}
  end

  describe "write/1" do
    @tag :unit
    test "writes to the configured device", %{original: original} do
      {:ok, string_io} = StringIO.open("")
      Application.put_env(:nucleus, Nucleus.Audit, Keyword.put(original, :device, string_io))

      assert Device.write(["hello audit\n"]) == :ok
      assert {_input, "hello audit\n"} = StringIO.contents(string_io)
    end

    @tag :unit
    test ":stderr default is distinct from the Logger device (AUD-A06)" do
      configured = Application.fetch_env!(:nucleus, Nucleus.Audit) |> Keyword.get(:device)

      assert configured == :stderr
      # Logger's default handler writes to :stdio (standard output) unless a
      # deployment redirects it — see docs/adr/0004-audit-emission.md.
      refute configured == :stdio
    end
  end

  describe "cast_device_name/1" do
    @tag :unit
    test "maps the AUDIT_DEVICE names to real IO device atoms" do
      assert Device.cast_device_name("stdout") == {:ok, :stdio}
      assert Device.cast_device_name("stderr") == {:ok, :stderr}
    end

    @tag :unit
    test "there is no :stdout IO device — writing to it raises" do
      # The bug this guards against: config/runtime.exs must never pass
      # "stdout" through as the literal atom :stdout.
      assert_raise ArgumentError, fn -> IO.write(:stdout, "x") end
    end

    @tag :unit
    test "returns :error for anything else, treated as a file path upstream" do
      assert Device.cast_device_name("/var/log/audit.log") == :error
      assert Device.cast_device_name("") == :error
    end
  end
end
