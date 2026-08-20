defmodule Nucleus.BackendTest do
  # Mutates :nucleus, :backends application config, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nucleus.Backend
  alias Nucleus.Backend.Error

  doctest Nucleus.Backend
  doctest Nucleus.Backend.Error

  # Any loaded module satisfies impl_for/1 — it checks that the configured module
  # exists, not that it implements a behaviour. The real and local
  # implementations arrive in EN-3/EN-4, so tests that need a *loaded* module
  # stand in with one that already exists.
  @loaded_module Nucleus.Backend.Error

  setup do
    original = Application.get_env(:nucleus, :backends)
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)
    :ok
  end

  defp put_backend(boundary, module) do
    configured = Application.get_env(:nucleus, :backends, [])
    Application.put_env(:nucleus, :backends, Keyword.put(configured, boundary, module))
  end

  describe "boundaries/0" do
    @tag :unit
    test "covers secrets, tenant_api, and m2m, and no auth boundary" do
      assert Backend.boundaries() == [:m2m, :secrets, :tenant_api]
      refute :auth in Backend.boundaries()
    end
  end

  describe "impl_for/1" do
    @tag :unit
    test "returns the configured module for each boundary" do
      for boundary <- Backend.boundaries() do
        put_backend(boundary, @loaded_module)
        assert Backend.impl_for(boundary) == @loaded_module
      end
    end

    @tag :unit
    test "raises an actionable error for an unknown boundary" do
      # Built at runtime: the compiler's type checker rejects the literal, since
      # it knows :nomad is outside the declared boundary union.
      unknown = String.to_atom("nomad")

      error = assert_raise ArgumentError, fn -> Backend.impl_for(unknown) end

      assert error.message =~ "unknown backend boundary: :nomad"
      assert error.message =~ "Known boundaries: [:m2m, :secrets, :tenant_api]"
    end

    @tag :unit
    test "raises an actionable error when the boundary is unconfigured" do
      Application.put_env(:nucleus, :backends, [])

      error = assert_raise RuntimeError, fn -> Backend.impl_for(:secrets) end

      assert error.message =~ "no backend configured for boundary :secrets"
      assert error.message =~ "SECRETS_BACKEND=local"
    end

    @tag :unit
    test "raises when configured to a module that does not exist" do
      put_backend(:secrets, Nucleus.Secrets.Store.DoesNotExist)

      error = assert_raise RuntimeError, fn -> Backend.impl_for(:secrets) end

      assert error.message =~ "Nucleus.Secrets.Store.DoesNotExist"
      assert error.message =~ "not a loaded module"
      # Names both alternatives, so the reader knows what to configure instead.
      assert error.message =~ "Nucleus.Secrets.Store.Aws"
      assert error.message =~ "Nucleus.Secrets.Store.Local"
    end
  end

  describe "impl_for_mode!/2" do
    @tag :unit
    test "resolves both modes for every boundary" do
      for boundary <- Backend.boundaries() do
        assert is_atom(Backend.impl_for_mode!(boundary, :real))
        assert is_atom(Backend.impl_for_mode!(boundary, :local))
        refute Backend.impl_for_mode!(boundary, :real) == Backend.impl_for_mode!(boundary, :local)
      end
    end

    @tag :unit
    test "accepts the string modes runtime.exs reads from the environment" do
      assert Backend.impl_for_mode!(:secrets, "real") == Backend.impl_for_mode!(:secrets, :real)
      assert Backend.impl_for_mode!(:secrets, "local") == Backend.impl_for_mode!(:secrets, :local)
    end

    @tag :unit
    test "raises on an unrecognised mode rather than falling back to real" do
      error = assert_raise ArgumentError, fn -> Backend.impl_for_mode!(:secrets, "Local") end

      assert error.message =~ "invalid backend mode \"Local\""
      assert error.message =~ "SECRETS_BACKEND"
    end
  end

  describe "env_var/1" do
    @tag :unit
    test "matches the documented variable names" do
      assert Backend.env_var(:secrets) == "SECRETS_BACKEND"
      assert Backend.env_var(:tenant_api) == "TENANT_API_BACKEND"
      assert Backend.env_var(:m2m) == "M2M_BACKEND"
    end
  end

  describe "local backend warning" do
    @tag :unit
    test "config/test.exs selects the local implementation for every boundary" do
      # Guards against drift between the literal module names in config and the
      # registry in Nucleus.Backend — config files cannot call the registry.
      assert Backend.local_boundaries() == Backend.boundaries()
    end

    @tag :unit
    test "warns once, naming each local boundary and its override variable" do
      log = capture_log(fn -> assert Backend.warn_on_local_backends() == :ok end)

      assert log =~ "LOCAL BACKENDS ACTIVE"
      assert log =~ "secrets -> Nucleus.Secrets.Store.Local (SECRETS_BACKEND=local)"
      assert log =~ "tenant_api -> Nucleus.TenantApi.Local (TENANT_API_BACKEND=local)"
      assert log =~ "m2m -> Nucleus.M2M.Clients.Local (M2M_BACKEND=local)"
    end

    @tag :unit
    test "stays silent when every boundary is real" do
      for boundary <- Backend.boundaries() do
        put_backend(boundary, Backend.impl_for_mode!(boundary, :real))
      end

      assert Backend.local_boundaries() == []
      assert capture_log(fn -> Backend.warn_on_local_backends() end) == ""
    end
  end

  describe "Error" do
    @tag :unit
    test "new/4 populates boundary and defaults details to %{}" do
      error = Error.new(:not_found, :secrets, "no such parameter")

      assert %Error{kind: :not_found, boundary: :secrets, message: "no such parameter"} = error
      assert error.details == %{}
    end

    @tag :unit
    test "new/4 carries structured details" do
      error = Error.new(:unavailable, :tenant_api, "timeout", %{status: 504})

      assert error.details == %{status: 504}
    end

    @tag :unit
    test "new/4 rejects a kind outside the union" do
      # Built at runtime for the same reason as above.
      invalid_kind = String.to_atom("teapot")

      assert_raise FunctionClauseError, fn -> Error.new(invalid_kind, :secrets, "nope") end
    end

    @tag :unit
    test "kinds/0 matches the @type kind union" do
      # The guard that stops a seventh kind being added without every `case`
      # that matches on one being revisited.
      assert Enum.sort(Error.kinds()) == Enum.sort(declared_kinds())
    end

    @tag :unit
    test "kinds/0 covers every requirement failure mode" do
      assert Enum.sort(Error.kinds()) ==
               Enum.sort([
                 :invalid,
                 :not_found,
                 :already_exists,
                 :auth_expired,
                 :unavailable,
                 :not_configured
               ])
    end

    @tag :unit
    test "cast_kind/1 round-trips every kind and rejects anything else" do
      for kind <- Error.kinds() do
        assert Error.cast_kind(Atom.to_string(kind)) == {:ok, kind}
      end

      assert Error.cast_kind("teapot") == :error
      assert Error.cast_kind("") == :error
    end

    @tag :unit
    test "is a plain struct, not an exception" do
      # Backends return these; they never raise them. If Error ever became an
      # exception, `rescue` would become a plausible control-flow choice in a
      # handle_event/3.
      refute function_exported?(Error, :exception, 1)
    end
  end

  # The kinds declared by `@type kind`, read back out of the compiled type chunk.
  defp declared_kinds do
    {:ok, types} = Code.Typespec.fetch_types(Error)

    {:type, {:kind, {:type, _meta, :union, members}, []}} =
      Enum.find(types, &match?({:type, {:kind, _definition, []}}, &1))

    Enum.map(members, fn {:atom, _line, kind} -> kind end)
  end
end
