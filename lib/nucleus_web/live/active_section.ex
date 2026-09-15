defmodule NucleusWeb.ActiveSection do
  @moduledoc """
  Maps a request path to the sidebar section it belongs to, for `NAV-A03`'s
  active-section highlighting.

  A pure function, unit-tested directly with no LiveView mount — the same
  shape as `NucleusWeb.SidebarEnvironments.group/1`. `NucleusWeb.ShellHook`
  is the only caller; it reads the connection URI on every `handle_params`
  and assigns the result to `:active_section`, which `NucleusWeb.Layouts.app/1`
  renders against.

  ## `"/"` and `"/applications"` both resolve to `:applications`

  `router.ex` serves `NucleusWeb.ApplicationsLive` at both paths (`NAV-A01`)
  — two routes, same module, same `:index` action, no redirect hop. Since
  both paths render the same view, both must highlight the same sidebar
  item.

  ## Viewing an environment highlights nothing tenant-wide

  `"/environments/:environment"` and its `/secrets` child resolve to
  `:environments`, not `nil` and not one of the three tenant-wide items.
  This prevents a stale highlight left over from whichever sidebar link was
  clicked last to reach an environment. It does not mean the Environments
  sidebar *section* itself gets highlighted — no sidebar element currently
  reads the `:environments` result; only the three tenant-wide links
  (`#nav-applications`, `#nav-data-export`, `#nav-m2m-clients`) inspect
  `@active_section` in `layouts.ex`, and it matches none of them for this
  value. Highlighting the active environment child link itself is out of
  scope for `NAV-A03`, which names only the three tenant-wide items.

  ## Unrecognized paths resolve to `nil`

  No item is highlighted — matching the shell's "remains visible, no broken
  page" contract for an unrecognized URL (`Application-Shell-and-Navigation.md`'s
  error/edge-case matrix).
  """

  @type section :: :applications | :data_export | :m2m_clients | :environments | nil

  @doc """
  Resolves `path` (as returned by `URI.parse(uri).path`) to the sidebar
  section it belongs to.

      iex> NucleusWeb.ActiveSection.for_path("/")
      :applications

      iex> NucleusWeb.ActiveSection.for_path("/applications")
      :applications

      iex> NucleusWeb.ActiveSection.for_path("/data-export")
      :data_export

      iex> NucleusWeb.ActiveSection.for_path("/m2m/clients")
      :m2m_clients

      iex> NucleusWeb.ActiveSection.for_path("/m2m/clients/abc123")
      :m2m_clients

      iex> NucleusWeb.ActiveSection.for_path("/environments/prod")
      :environments

      iex> NucleusWeb.ActiveSection.for_path("/environments/prod/secrets")
      :environments

      iex> NucleusWeb.ActiveSection.for_path("/does-not-exist")
      nil
  """
  @spec for_path(String.t()) :: section()
  def for_path(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> section_for_segments()
  end

  defp section_for_segments([]), do: :applications
  defp section_for_segments(["applications"]), do: :applications
  defp section_for_segments(["data-export"]), do: :data_export
  defp section_for_segments(["m2m", "clients"]), do: :m2m_clients
  defp section_for_segments(["m2m", "clients", _client_id]), do: :m2m_clients
  defp section_for_segments(["environments", _environment]), do: :environments
  defp section_for_segments(["environments", _environment, "secrets"]), do: :environments
  defp section_for_segments(_segments), do: nil
end
