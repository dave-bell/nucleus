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
  # Swaps the configured implementation, application-global (the Store
  # dispatch tests below), plus seeds/faults the local backend and asserts
  # on emitted audit records (the Nucleus.NomadVars context tests, DEX-S1)
  # — composed the same way Nucleus.M2MTest is, both pinned to
  # async: false to match Nucleus.BackendCase's constraint.
  use Nucleus.BackendCase, async: false
  use Nucleus.AuditCase, async: false

  alias Nucleus.Backend
  alias Nucleus.Backend.Error
  alias Nucleus.NomadVars
  alias Nucleus.NomadVars.FakeStore
  alias Nucleus.NomadVars.Store
  alias Nucleus.NomadVars.Value
  alias Nucleus.NomadVars.VariableSet
  alias Nucleus.Scope

  @scope %Scope{tenant: "local", user: %{email: "a@b.com", username: nil}}

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

  describe "Nucleus.NomadVars.fetch/1 — no audit, ever" do
    test "returns {:ok, var_set} for the seeded enabled fixture, with no audit emission" do
      assert {:ok, %VariableSet{} = var_set} = NomadVars.fetch(@scope)

      assert var_set.path == "nomad/jobs/local-data_export"
      assert_no_audit_event(:nomad_vars_listed)
    end

    test "a :not_found tenant emits nothing either" do
      Backend.Seed.write(:nomad_vars, false)

      assert {:error, %Error{kind: :not_found}} = NomadVars.fetch(@scope)
      assert_no_audit_event(:nomad_vars_listed)
    end
  end

  describe "Nucleus.NomadVars.list/1 — DEX-A03 the seeded enabled fixture" do
    @tag action: "DEX-A03"
    test "returns {:ok, var_set} with every seeded key/value" do
      assert {:ok, %VariableSet{} = var_set} = NomadVars.list(@scope)

      assert var_set.path == "nomad/jobs/local-data_export"
      assert var_set.items["description"] =~ "Nightly export"
      assert var_set.items["env_names"] == "prod,staging"
      assert is_integer(var_set.modify_index)
    end

    @tag action: "DEX-A03"
    test "emits exactly one nomad_vars_listed, with the path in details and the tenant set" do
      assert {:ok, var_set} = NomadVars.list(@scope)

      assert_audit_event(:nomad_vars_listed,
        tenant: "local",
        details: %{path: var_set.path}
      )

      assert audit_events() |> Enum.filter(&(&1.event == :nomad_vars_listed)) |> length() == 1
    end
  end

  describe "Nucleus.NomadVars.list/1 — no audit on any error" do
    @tag action: "DEX-A01"
    test "a tenant with no Data Export variable path (:not_found) emits nothing" do
      Backend.Seed.write(:nomad_vars, false)

      assert {:error, %Error{kind: :not_found}} = NomadVars.list(@scope)
      assert_no_audit_event(:nomad_vars_listed)
    end

    test "an unconfigured boundary (:not_configured) emits nothing" do
      Backend.Seed.write(:nomad_vars, nil)

      assert {:error, %Error{kind: :not_configured}} = NomadVars.list(@scope)
      assert_no_audit_event(:nomad_vars_listed)
    end

    test "an unavailable backend emits nothing" do
      force_error(:nomad_vars, :unavailable)

      assert {:error, %Error{kind: :unavailable}} = NomadVars.list(@scope)
      assert_no_audit_event(:nomad_vars_listed)
    end
  end

  describe "Nucleus.NomadVars.list/1 — every Error.kind() passes through unchanged" do
    for kind <- Error.kinds() do
      @tag kind: kind
      test "#{kind} is returned unflattened, :not_found included, with no translation", %{
        kind: kind
      } do
        force_error(:nomad_vars, kind)

        assert {:error, %Error{kind: ^kind, boundary: :nomad_vars}} = NomadVars.list(@scope)
        assert_no_audit_event(:nomad_vars_listed)
      end
    end
  end

  describe "Nucleus.NomadVars.update/5 — DEX-A05 a matching index succeeds" do
    @tag action: "DEX-A05"
    test "replaces the target key, returns the bumped VariableSet, and leaves other keys unchanged" do
      {:ok, %VariableSet{items: items, modify_index: modify_index}} = NomadVars.fetch(@scope)

      assert {:ok, %VariableSet{} = updated} =
               NomadVars.update(
                 "description",
                 "Updated nightly export.",
                 items,
                 modify_index,
                 @scope
               )

      assert updated.items["description"] == "Updated nightly export."
      assert updated.modify_index > modify_index

      # Proves the new Items map was built from the caller's full map, not a
      # partial write that would have clobbered every other key.
      assert updated.items["env_names"] == items["env_names"]
      assert updated.items["destination_bucket"] == items["destination_bucket"]
    end

    @tag action: "DEX-A05"
    test "emits nomad_var_updated on success, with path and key in details and no value anywhere" do
      {:ok, %VariableSet{items: items, modify_index: modify_index}} = NomadVars.fetch(@scope)

      assert {:ok, %VariableSet{} = updated} =
               NomadVars.update(
                 "description",
                 "Updated nightly export.",
                 items,
                 modify_index,
                 @scope
               )

      event =
        assert_audit_event(:nomad_var_updated,
          tenant: "local",
          details: %{path: updated.path, key: "description"}
        )

      refute Map.has_key?(event.details, :value)
      refute Map.has_key?(event, :value)
    end
  end

  describe "Nucleus.NomadVars.update/5 — DEX-A05 value shape validation, before Store.write/2 is ever called" do
    @tag action: "DEX-A05"
    test "an empty value returns {:error, %Error{kind: :invalid}}, no write, no audit" do
      {:ok, %VariableSet{items: items, modify_index: modify_index}} = NomadVars.fetch(@scope)

      assert {:error, %Error{kind: :invalid, boundary: :nomad_vars}} =
               NomadVars.update("description", "", items, modify_index, @scope)

      assert_no_audit_event(:nomad_var_updated)

      # The store was never written to — the same modify_index and items
      # from before the rejected call are still current.
      assert {:ok, %VariableSet{modify_index: ^modify_index, items: ^items}} =
               NomadVars.fetch(@scope)
    end

    @tag action: "DEX-A05"
    test "a value over Value.max_length/0 characters returns {:error, %Error{kind: :invalid}}, no write, no audit" do
      {:ok, %VariableSet{items: items, modify_index: modify_index}} = NomadVars.fetch(@scope)
      too_long = String.duplicate("a", Value.max_length() + 1)

      assert {:error, %Error{kind: :invalid, boundary: :nomad_vars}} =
               NomadVars.update("description", too_long, items, modify_index, @scope)

      assert_no_audit_event(:nomad_var_updated)

      assert {:ok, %VariableSet{modify_index: ^modify_index, items: ^items}} =
               NomadVars.fetch(@scope)
    end

    @tag action: "DEX-A05"
    test "an invalid value is rejected even against a stale index — validation runs before the CAS check" do
      {:ok, %VariableSet{items: items, modify_index: modify_index}} = NomadVars.fetch(@scope)
      stale_index = modify_index - 1

      assert {:error, %Error{kind: :invalid}} =
               NomadVars.update("description", "", items, stale_index, @scope)
    end
  end

  describe "Nucleus.NomadVars.update/5 — DEX-A06 a stale index conflicts, silently" do
    @tag action: "DEX-A06"
    test "a stale expected_modify_index returns {:error, %Error{kind: :conflict}}, no audit emitted" do
      {:ok, %VariableSet{items: items, modify_index: modify_index}} = NomadVars.fetch(@scope)
      stale_index = modify_index - 1

      assert {:error, %Error{kind: :conflict}} =
               NomadVars.update("description", "Racing edit.", items, stale_index, @scope)

      assert_no_audit_event(:nomad_var_updated)
    end
  end

  describe "Nucleus.NomadVars.update/5 — every other Error.kind() passes through unchanged, no audit" do
    for kind <- Error.kinds() do
      @tag kind: kind
      test "#{kind} is returned unflattened, with no translation and no audit emission", %{
        kind: kind
      } do
        {:ok, %VariableSet{items: items, modify_index: modify_index}} = NomadVars.fetch(@scope)
        force_error(:nomad_vars, kind)

        assert {:error, %Error{kind: ^kind, boundary: :nomad_vars}} =
                 NomadVars.update("description", "value", items, modify_index, @scope)

        assert_no_audit_event(:nomad_var_updated)
      end
    end
  end
end
