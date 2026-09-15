defmodule Nucleus.NomadVars.EnvNames do
  @moduledoc """
  Pure logic for `env_names` — the comma-separated string round-trip and the
  add/remove delta `DEX-A10`'s audit requirement (`AUD-A04`) needs. Sibling
  of `Nucleus.NomadVars.Value`: same directory, same "one small module per
  concern" shape, no I/O, no `Nucleus.Backend` boundary of its own.

  ## `serialize/1`/`parse/1` — one format decision, not two copies of it

  `NucleusWeb.DataExportLive.EnvironmentPicker` (DEX-S3, opening the picker)
  and `Nucleus.NomadVars.update_env_names/4` (DEX-S4, saving it) both need
  the same comma-separated-string convention `env_names` is stored under —
  the picker to parse the stored value into a pre-selection, the save path
  to serialize the picker's selection back into a string to write. Before
  this module existed, `parse/1`'s logic lived once, privately, inside
  `NucleusWeb.DataExportLive` (`parse_env_names/1`) — factored out here so
  the picker and the save path share one implementation instead of two
  independently-maintained copies of the same decision drifting apart.

  ## No `:unset`/`"none"` sentinel, unlike `Nucleus.M2M.DenyList.parse/1`

  `DenyList.parse/1`'s sentinel handling exists because an *unconfigured*
  deny-list must fail closed rather than silently behave like an empty one
  (Decision 2). `env_names` has no equivalent unconfigured state to guard
  against — an empty selection is exactly `[]`, a perfectly valid and
  representable choice (Data Export enabled for zero environments), not a
  signal that something upstream forgot to set a value. `parse/1` below is
  `DenyList.parse/1`'s whitespace/blank-entry tolerance only, with the
  sentinel branch removed.

  ## `diff/2` sorts both sides — determinism, not `MapSet` internals

  `added`/`removed` are computed with the `--` list-subtraction operator
  and then `Enum.sort/1`, not left in whatever order `--` (or a `MapSet`)
  happens to produce. `env_names_updated`'s audit record is a permanent,
  compliance-facing artifact (`AUD-A04`); an unsorted diff would make its
  field order depend on an implementation detail (list traversal order,
  `MapSet`'s internal hashing) that is not a promise anyone downstream
  should rely on. Sorting once, here, means every caller and every audit
  record gets the same order for the same inputs, regardless of how
  `EnvironmentPicker.selected_names/1` happened to build its own list.
  """

  @type delta :: %{added: [String.t()], removed: [String.t()]}

  @doc """
  The add/remove delta between `current` and `new` — what `env_names_updated`
  (`DEX-A10`, `AUD-A04`) records. Both `:added` and `:removed` are always
  present, sorted, and may be `[]` — an explicit empty list, never an absent
  key, so a no-op save still has a fully-shaped delta to audit.

      iex> Nucleus.NomadVars.EnvNames.diff(["prod"], ["prod", "staging"])
      %{added: ["staging"], removed: []}

      iex> Nucleus.NomadVars.EnvNames.diff(["prod", "staging"], ["prod"])
      %{added: [], removed: ["staging"]}

      iex> Nucleus.NomadVars.EnvNames.diff(["staging", "prod"], ["qa", "dev"])
      %{added: ["dev", "qa"], removed: ["prod", "staging"]}

      iex> Nucleus.NomadVars.EnvNames.diff(["prod", "staging"], ["prod", "staging"])
      %{added: [], removed: []}

      iex> Nucleus.NomadVars.EnvNames.diff([], [])
      %{added: [], removed: []}
  """
  @spec diff(current :: [String.t()], new :: [String.t()]) :: delta()
  def diff(current, new) when is_list(current) and is_list(new) do
    %{
      added: Enum.sort(new -- current),
      removed: Enum.sort(current -- new)
    }
  end

  @doc """
  Joins `names` into the comma-separated string `env_names` is stored as.

  The inverse of `parse/1`: `parse(serialize(names)) == names` for any list
  already free of blank/whitespace-only entries (see `parse/1`'s doctests
  for the round-trip on both a single-entry and an empty list).

      iex> Nucleus.NomadVars.EnvNames.serialize(["prod", "staging"])
      "prod,staging"

      iex> Nucleus.NomadVars.EnvNames.serialize(["prod"])
      "prod"

      iex> Nucleus.NomadVars.EnvNames.serialize([])
      ""
  """
  @spec serialize([String.t()]) :: String.t()
  def serialize(names) when is_list(names), do: Enum.join(names, ",")

  @doc """
  Parses a raw `env_names` value into a list of environment short names.

  Pure — no I/O, no config read, no sentinel (see the moduledoc's "No
  `:unset`/`\"none\"` sentinel" section). `nil` and `""` both parse to `[]`;
  stray whitespace around entries and blank entries between commas (a
  trailing comma, a doubled comma) are tolerated and dropped, matching
  `Nucleus.M2M.DenyList.parse/1`'s own whitespace tolerance.

      iex> Nucleus.NomadVars.EnvNames.parse(nil)
      []

      iex> Nucleus.NomadVars.EnvNames.parse("")
      []

      iex> Nucleus.NomadVars.EnvNames.parse("prod,staging")
      ["prod", "staging"]

      iex> Nucleus.NomadVars.EnvNames.parse(" prod , staging ")
      ["prod", "staging"]

      iex> Nucleus.NomadVars.EnvNames.parse("prod,,staging,")
      ["prod", "staging"]

      iex> Nucleus.NomadVars.EnvNames.parse("prod")
      ["prod"]
  """
  @spec parse(String.t() | nil) :: [String.t()]
  def parse(nil), do: []

  def parse(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
