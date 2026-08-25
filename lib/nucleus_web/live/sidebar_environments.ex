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
