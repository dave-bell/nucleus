defmodule Nucleus.Backend.FaultsTest do
  # Mutates OS environment variables, which are global to the VM.
  use ExUnit.Case, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Faults

  @latency_var "LOCAL_LATENCY_MS"
  @error_var "LOCAL_FORCE_ERROR"

  setup do
    on_exit(fn ->
      System.delete_env(@latency_var)
      System.delete_env(@error_var)
    end)

    System.delete_env(@latency_var)
    System.delete_env(@error_var)

    :ok
  end

  describe "maybe_fault/1 with no faults configured" do
    @tag :unit
    test "returns :ok when neither env var is set" do
      assert Faults.maybe_fault(:secrets) == :ok
    end

    @tag :unit
    test "treats an empty value as unset" do
      System.put_env(@latency_var, "")
      System.put_env(@error_var, "")

      assert Faults.maybe_fault(:secrets) == :ok
    end
  end

  describe "LOCAL_FORCE_ERROR" do
    @tag :unit
    test "auth_expired yields an :auth_expired error, so SEC-S7 is testable" do
      System.put_env(@error_var, "auth_expired")

      assert {:error, %Error{kind: :auth_expired, boundary: :secrets} = error} =
               Faults.maybe_fault(:secrets)

      assert error.details == %{injected: true}
      assert error.message =~ @error_var
    end

    @tag :unit
    test "unavailable yields an :unavailable error, so SEC-S1 fail-closed is testable" do
      System.put_env(@error_var, "unavailable")

      assert {:error, %Error{kind: :unavailable, boundary: :tenant_api}} =
               Faults.maybe_fault(:tenant_api)
    end

    @tag :unit
    test "every error kind can be injected" do
      for kind <- Error.kinds() do
        System.put_env(@error_var, Atom.to_string(kind))
        assert {:error, %Error{kind: ^kind}} = Faults.maybe_fault(:secrets)
      end
    end

    @tag :unit
    test "an unparseable value raises rather than silently returning :ok" do
      # A typo in a fault flag must not produce a false-passing test.
      System.put_env(@error_var, "auth-expired")

      error = assert_raise ArgumentError, fn -> Faults.maybe_fault(:secrets) end

      assert error.message =~ @error_var
      assert error.message =~ "auth-expired"
      assert error.message =~ "auth_expired"
    end

    @tag :unit
    test "is read on every call, so a fault can be flipped without a restart" do
      assert Faults.maybe_fault(:secrets) == :ok

      System.put_env(@error_var, "not_found")
      assert {:error, %Error{kind: :not_found}} = Faults.maybe_fault(:secrets)

      System.delete_env(@error_var)
      assert Faults.maybe_fault(:secrets) == :ok
    end
  end

  describe "LOCAL_LATENCY_MS" do
    @tag :unit
    test "delays the return by at least the configured duration" do
      System.put_env(@latency_var, "40")

      {elapsed_us, result} = :timer.tc(fn -> Faults.maybe_fault(:secrets) end)

      assert result == :ok
      assert elapsed_us >= 40_000
    end

    @tag :unit
    test "applies before a forced error, so loading states are exercised too" do
      System.put_env(@latency_var, "20")
      System.put_env(@error_var, "unavailable")

      {elapsed_us, result} = :timer.tc(fn -> Faults.maybe_fault(:secrets) end)

      assert {:error, %Error{kind: :unavailable}} = result
      assert elapsed_us >= 20_000
    end

    @tag :unit
    test "accepts zero" do
      System.put_env(@latency_var, "0")

      assert Faults.maybe_fault(:secrets) == :ok
    end

    @tag :unit
    test "an unparseable value raises rather than being ignored" do
      System.put_env(@latency_var, "40ms")

      error = assert_raise ArgumentError, fn -> Faults.maybe_fault(:secrets) end

      assert error.message =~ @latency_var
      assert error.message =~ "non-negative integer"
    end

    @tag :unit
    test "a negative value raises" do
      System.put_env(@latency_var, "-1")

      assert_raise ArgumentError, fn -> Faults.maybe_fault(:secrets) end
    end
  end
end
