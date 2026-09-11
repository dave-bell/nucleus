defmodule NucleusWeb.DataExportLive.EnvironmentPicker do
  @moduledoc """
  Pure state for the `env_names` environment picker (`DEX-A07`–`A09`) — a
  real shared module, not a private helper inlined in
  `NucleusWeb.DataExportLive`, the same "substantial enough for its own file
  and its own unit tests" reasoning `NucleusWeb.M2MClientsLive.Format`
  established for a smaller case.

  ## One `MapSet` of selected short names, not two lists

  `toggle/2` moves a `short_name` between "available" and "selected" by
  flipping membership in a single `MapSet`, against the picker's full,
  unpartitioned `all` list — not by moving an `%Environment{}` struct
  between two separate lists. An environment's identity (and its position
  in `all`'s original sort order) survives any sequence of filter/toggle
  calls without ever needing to be re-looked-up from a partitioned list
  that dropped it.

  ## Filtering narrows what's shown, never the selection itself

  `available_matches/1` and `selected_matches/1` both partition `all` by
  current selection membership, then narrow *that* partition to `filter`'s
  case-insensitive substring match against `short_name` or `label`. A
  selected environment that the current filter hides from
  `selected_matches/1` remains selected — `DEX-A09` narrows what the two
  lists *display*, not the underlying selection `DEX-A08` built. Clearing
  `filter` (back to `""`) always restores the full partition, since an
  empty query matches everything.

  ## Construction is the only place selection comes from

  `new/2` is the sole entry point that sets `selected` from an outside
  source — normally `env_names`'s current stored value, parsed at open
  time by the caller. Every other function only ever moves or reads that
  set; nothing here re-derives it from anywhere else, so a caller that
  wants "start over from the current stored value" (reopening after a
  cancel) must call `new/2` again with a fresh read, not reuse an existing
  `t()`.
  """

  alias Nucleus.TenantApi.Environment

  @enforce_keys [:all, :selected, :filter]
  defstruct [:all, :selected, :filter]

  @type t :: %__MODULE__{
          all: [Environment.t()],
          selected: MapSet.t(String.t()),
          filter: String.t()
        }

  @doc """
  Builds a picker over `available` environments, pre-selecting exactly
  `selected_names`.

  `available` is expected already filtered (non-archived) and sorted by
  the caller — this module has no opinion on either; it only tracks
  selection and filter state over whatever list it is given.
  """
  @spec new(available :: [Environment.t()], selected_names :: [String.t()]) :: t()
  def new(available, selected_names) when is_list(available) and is_list(selected_names) do
    %__MODULE__{
      all: available,
      selected: MapSet.new(selected_names),
      filter: ""
    }
  end

  @doc """
  Moves `short_name` between selected and available.

  Idempotent under a double-toggle back to the same short name — the
  second call simply reverses the first `MapSet.put/2`/`MapSet.delete/2`.
  """
  @spec toggle(t(), short_name :: String.t()) :: t()
  def toggle(%__MODULE__{selected: selected} = picker, short_name) when is_binary(short_name) do
    selected =
      if MapSet.member?(selected, short_name) do
        MapSet.delete(selected, short_name)
      else
        MapSet.put(selected, short_name)
      end

    %{picker | selected: selected}
  end

  @doc """
  Sets the filter query used by `available_matches/1` and
  `selected_matches/1`. Does not touch `selected`.
  """
  @spec filter(t(), query :: String.t()) :: t()
  def filter(%__MODULE__{} = picker, query) when is_binary(query) do
    %{picker | filter: query}
  end

  @doc """
  The currently selected short names — what `DEX-A10`'s save (a future
  ticket) reads to compute the final `env_names` value.
  """
  @spec selected_names(t()) :: [String.t()]
  def selected_names(%__MODULE__{selected: selected}) do
    MapSet.to_list(selected)
  end

  @doc """
  Count of selected environments still present in `all` — what the
  "Active (N)" badge shows, kept in lockstep with `selected_matches/1`'s
  unfiltered row count rather than `length(selected_names/1)`.

  `selected` can contain short names absent from `all` (`env_names` was
  hand-edited before Nucleus existed, and an entry may reference an
  environment that's since been archived, renamed, or never existed at
  all). `selected_names/1` intentionally still returns those — `DEX-A10`'s
  save must not silently drop a stored value it can't otherwise account
  for — but the badge counting them would disagree with the rows
  `selected_matches/1` actually renders, e.g. "Active (2)" over a single
  visible row with no way to see or clear the phantom entry. Counting the
  same `all`-intersection `selected_matches/1` filters keeps the two in
  sync; ignoring the filter here (unlike `selected_matches/1`) keeps the
  count itself filter-independent, matching how the selection is filter-
  independent.
  """
  @spec selected_count(t()) :: non_neg_integer()
  def selected_count(%__MODULE__{all: all, selected: selected}) do
    Enum.count(all, &MapSet.member?(selected, &1.short_name))
  end

  @doc """
  Environments not currently selected, narrowed by the current filter.
  """
  @spec available_matches(t()) :: [Environment.t()]
  def available_matches(%__MODULE__{all: all, selected: selected, filter: filter}) do
    all
    |> Enum.reject(&MapSet.member?(selected, &1.short_name))
    |> matching(filter)
  end

  @doc """
  Currently selected environments, narrowed by the current filter — the
  filter hides rows here without deselecting them.
  """
  @spec selected_matches(t()) :: [Environment.t()]
  def selected_matches(%__MODULE__{all: all, selected: selected, filter: filter}) do
    all
    |> Enum.filter(&MapSet.member?(selected, &1.short_name))
    |> matching(filter)
  end

  defp matching(environments, ""), do: environments

  defp matching(environments, filter) do
    query = String.downcase(filter)
    Enum.filter(environments, &matches?(&1, query))
  end

  defp matches?(%Environment{short_name: short_name, label: label}, query) do
    String.contains?(String.downcase(short_name), query) or
      (is_binary(label) and String.contains?(String.downcase(label), query))
  end
end
