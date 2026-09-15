defmodule NucleusWeb.ActiveSectionTest do
  use ExUnit.Case, async: true

  alias NucleusWeb.ActiveSection

  doctest ActiveSection

  @tag action: "NAV-A03"
  test "\"/\" and \"/applications\" both resolve to :applications" do
    assert ActiveSection.for_path("/") == :applications
    assert ActiveSection.for_path("/applications") == :applications
  end

  @tag action: "NAV-A03"
  test "\"/data-export\" resolves to :data_export" do
    assert ActiveSection.for_path("/data-export") == :data_export
  end

  @tag action: "NAV-A03"
  test "\"/m2m/clients\" and \"/m2m/clients/:client_id\" both resolve to :m2m_clients" do
    assert ActiveSection.for_path("/m2m/clients") == :m2m_clients
    assert ActiveSection.for_path("/m2m/clients/abc123") == :m2m_clients
  end

  @tag action: "NAV-A03"
  test "\"/environments/:environment\" and \"/environments/:environment/secrets\" both resolve to :environments" do
    assert ActiveSection.for_path("/environments/prod") == :environments
    assert ActiveSection.for_path("/environments/prod/secrets") == :environments
  end

  test "an unrecognized path resolves to nil" do
    assert ActiveSection.for_path("/does-not-exist") == nil
    assert ActiveSection.for_path("/environments") == nil
    assert ActiveSection.for_path("/m2m") == nil
  end
end
