defmodule NucleusWeb.SidebarEnvironments do
  @moduledoc """
  Groups environments by category for the sidebar's Environments section
  (`NAV-A04`).

  A pure function rather than logic inlined in `NucleusWeb.Layouts` — the
  "integration (mocked)" test layer both `Application-Shell-and-Navigation.md`
  and `Environments.md` name explicitly ("environment grouping/categorization
  logic") is only reachable without mounting a LiveView if grouping lives
  somewhere `group/1` can be unit-tested directly.

  ## This module owns archived-exclusion, not `NucleusWeb.EnvironmentsHook`

  Before `NAV-S1`, the hook filtered `archived?` out of the list it assigned,
  because it was also the only place grouping could have happened. Now that
  grouping has its own pure function, and `NAV-A04`'s acceptance bar
  ("archived excluded — unit-tested directly") requires proving exclusion at
  *this* layer without mounting a LiveView, `group/1` re-checks `archived?`
  itself and the hook no longer filters — passing it a raw, unfiltered list
  is exactly what the archived-exclusion unit tests below do. `@environments`
  in `NucleusWeb.Layouts` therefore now carries every environment the tenant
  has, archived included; nothing outside this module and `Layouts` reads
  that assign (`grep -rn "@environments" lib/` turns up only the layout and
  the four LiveViews that thread it through), so widening what it carries has
  no other caller to break.

  ## Grouping rules (`NAV-A04`)

  - An environment with `categories: ["a", "b"]` appears in both group `"a"`
    and group `"b"`'s environment lists.
  - An environment with `categories: []` goes into a single `:uncategorized`
    group.
  - Named category groups sort case-insensitively alphabetically, tie-broken
    by the original casing — the same convention `Nucleus.M2M.list/1` uses
    for client names.
  - The `:uncategorized` group always sorts last, regardless of where its
    (absent) name would fall alphabetically.
  - Each group carries `count`, the length of its own environment list —
    not a separate query.
  """

  alias Nucleus.TenantApi.Environment

  @type group :: %{
          category: String.t() | :uncategorized,
          environments: [Environment.t()],
          count: non_neg_integer()
        }

  @type slugged_group :: %{group: group(), slug: String.t()}

  @doc """
  Groups `environments` by category, archived environments excluded.

      iex> prod = %Nucleus.TenantApi.Environment{short_name: "prod", categories: ["Regulated", "Customer Facing"]}
      iex> dev = %Nucleus.TenantApi.Environment{short_name: "dev", categories: []}
      iex> NucleusWeb.SidebarEnvironments.group([prod, dev]) |> Enum.map(& &1.category)
      ["Customer Facing", "Regulated", :uncategorized]
  """
  @spec group([Environment.t()]) :: [group()]
  def group(environments) when is_list(environments) do
    environments
    |> Enum.reject(& &1.archived?)
    |> Enum.reduce(%{}, &put_categories/2)
    |> Enum.map(&build_group/1)
    |> Enum.sort_by(&sort_key/1)
  end

  @doc """
  Pairs each of `groups` with a DOM-safe, unique slug derived from its
  `:category`.

  `slug/1` alone is not injective: categories are free-form strings from the
  tenant API (no normalization guaranteed upstream), and two distinct
  categories that differ only by case or punctuation — `"Prod East"`,
  `"Prod-East"`, `"PROD_EAST"` — all lowercase-and-collapse to the same
  `"prod-east"`. `group/1` itself treats them as distinct groups (it keys on
  the exact string), so handing `layouts.ex` a colliding, non-unique slug for
  each would mean two unrelated categories render with the same DOM id and
  toggling one silently expands/collapses the other, since
  `NucleusWeb.EnvironmentsHook`'s `:expanded_categories` is a `MapSet` of
  slugs, not of category names.

  Disambiguates only when a collision actually occurs — appending `-2`,
  `-3`, ... to a later duplicate's base slug, in `groups`' own order (already
  deterministic per `group/1`'s sort). A category with no colliding sibling
  keeps its plain slug, unchanged from before this function existed. The
  suffix is stable across renders for a stable set of category names — it
  only shifts if the underlying categories themselves change, the same as
  any id derived from list position.

      iex> east = %{category: "Prod East", environments: [], count: 0}
      iex> dash = %{category: "Prod-East", environments: [], count: 0}
      iex> NucleusWeb.SidebarEnvironments.with_slugs([east, dash]) |> Enum.map(& &1.slug)
      ["prod-east", "prod-east-2"]
  """
  @spec with_slugs([group()]) :: [slugged_group()]
  def with_slugs(groups) do
    {slugged, _seen} =
      Enum.reduce(groups, {[], %{}}, fn group, {acc, seen} ->
        base = slug(group.category)
        count = Map.get(seen, base, 0) + 1
        unique_slug = if count == 1, do: base, else: "#{base}-#{count}"

        {[%{group: group, slug: unique_slug} | acc], Map.put(seen, base, count)}
      end)

    Enum.reverse(slugged)
  end

  @doc """
  The DOM-safe id fragment for a single category — `:uncategorized`, or a
  binary category name lowercased with every run of non-alphanumeric
  characters collapsed to a single `-`.

  Not guaranteed unique on its own across a list of categories — see
  `with_slugs/1`, which is what `layouts.ex` actually renders against.
  """
  @spec slug(String.t() | :uncategorized) :: String.t()
  def slug(:uncategorized), do: "uncategorized"

  def slug(category) when is_binary(category) do
    category
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp put_categories(%Environment{categories: []} = environment, acc) do
    Map.update(acc, :uncategorized, [environment], &[environment | &1])
  end

  defp put_categories(%Environment{categories: categories} = environment, acc) do
    Enum.reduce(categories, acc, fn category, acc ->
      Map.update(acc, category, [environment], &[environment | &1])
    end)
  end

  defp build_group({category, reversed_environments}) do
    environments = Enum.reverse(reversed_environments)
    %{category: category, environments: environments, count: length(environments)}
  end

  defp sort_key(%{category: :uncategorized}), do: {1, "", ""}
  defp sort_key(%{category: category}), do: {0, String.downcase(category), category}
end
