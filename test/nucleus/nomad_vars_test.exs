defmodule Nucleus.NomadVars.FakeStore do
  @moduledoc false
  # A minimal implementation used only by Nucleus.NomadVarsTest to prove
  # dispatch happens through Nucleus.Backend.impl_for/1, mirroring the
  # use_backend/1 precedent test/nucleus/nomad_jobs_test.exs and
  # test/nucleus/m2m_test.exs set for their own boundaries.
  @behaviour Nucleus.NomadVars.Store

  @impl Nucleus.NomadVars.Store
  def read do
    {:ok,
     %Nucleus.NomadVars.VariableSet{
       path: "nomad/jobs/fake-data_export",
       items: %{"description" => "from the fake store"},
       modify_index: 1,
       modified_at: nil
     }}
  end

  @impl Nucleus.NomadVars.Store
  def write(items, _expected_modify_index) do
    {:ok,
     %Nucleus.NomadVars.VariableSet{
       path: "nomad/jobs/fake-data_export",
       items: items,
       modify_index: 2,
       modified_at: nil
     }}
  end

  @impl Nucleus.NomadVars.Store
  def health_check, do: :ok
end

defmodule Nucleus.NomadVarsTest do
  # Swaps the configured implementation, application-global.
  use ExUnit.Case, async: false

  alias Nucleus.Backend
  alias Nucleus.NomadVars.FakeStore
  alias Nucleus.NomadVars.Store
  alias Nucleus.NomadVars.VariableSet

  setup do
    original_backends = Application.get_env(:nucleus, :backends)
    on_exit(fn -> Application.put_env(:nucleus, :backends, original_backends) end)
    :ok
  end

  defp use_backend(module) do
    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(Application.get_env(:nucleus, :backends, []), :nomad_vars, module)
    )
  end

  describe "the boundary is registered" do
    @tag :unit
    test "boundary/0 is :nomad_vars" do
      assert Store.boundary() == :nomad_vars
    end

    @tag :unit
    test ":nomad_vars appears in Backend.boundaries/0" do
      assert :nomad_vars in Backend.boundaries()
    end

    @tag :unit
    test "both registered implementations exist and implement the behaviour" do
      for mode <- [:real, :local] do
        module = Backend.impl_for_mode!(:nomad_vars, mode)

        assert Code.ensure_loaded?(module)
        assert {:module, ^module} = Code.ensure_loaded(module)
        assert Nucleus.NomadVars.Store in (module.module_info(:attributes)[:behaviour] || [])
      end
    end
  end

  describe "read/0, write/2, and health_check/0 dispatch through Backend.impl_for/1" do
    setup do
      use_backend(FakeStore)
      :ok
    end

    @tag :unit
    test "read/0 resolves to the configured implementation" do
      assert {:ok, %VariableSet{items: %{"description" => "from the fake store"}}} = Store.read()
    end

    @tag :unit
    test "write/2 resolves to the configured implementation" do
      assert {:ok, %VariableSet{items: %{"description" => "new"}, modify_index: 2}} =
               Store.write(%{"description" => "new"}, 1)
    end

    @tag :unit
    test "health_check/0 resolves to the configured implementation" do
      assert Store.health_check() == :ok
    end
  end
end
