defmodule Mix.Tasks.Nucleus.Trace do
  @shortdoc "Diffs requirement action IDs in docs/requirements/ against @tag action: in test/"

  @moduledoc """
  Requirement traceability, automated.

  `business-tech-bridge.md` defines the convention this task enforces: every
  wiki action (`### SEC-A03` in `docs/requirements/*.md`) should eventually be
  claimed by exactly one `@tag action: "SEC-A03"` in `test/`. Diffing those two
  lists by hand does not scale past a handful of tickets — this task is that
  diff, automated (see `living-notes.md`'s "Active Projects").

  ## Usage

      mix nucleus.trace
      mix nucleus.trace --feature SEC
      mix nucleus.trace --exitcode

  ## What it reports

    * **Covered** — defined in the requirements *and* claimed by a test.
    * **Uncovered** — defined, not yet claimed by any test.
    * **Claimed but undefined** — a test's `@tag action:` names an ID that
      does not exist in `docs/requirements/`. This is the failure mode a
      plain word count would miss: a typo'd or renumbered ID would otherwise
      silently show as coverage for the wrong requirement, or as coverage at
      all.

  ## Options

    * `--feature PREFIX` — restrict the report to one action prefix (e.g.
      `--feature SEC` for `SEC-A01`–`SEC-A18` only). Applies to all three
      buckets above.
    * `--exitcode` — exit non-zero when anything in scope is uncovered.
      Report-only by default, and **not** wired into the `precommit` alias —
      see `living-notes.md`: gating on total coverage while more than a
      dozen SEC tickets are still open would block every commit. Revisit
      once Secrets is complete.

  ## Why `Home.md` is excluded

  `docs/requirements/Home.md` contains a worked example of action formatting
  (`### SEC-A03 — Reveal a secret value`, in a "how to read an action"
  section) that is documentation, not a 115th requirement. Excluding it is
  what makes the defined count land on 114, not 115 — see
  `business-tech-bridge.md`.
  """

  use Mix.Task

  @requirements_glob "docs/requirements/*.md"
  @excluded_requirement_file "Home.md"
  @defined_pattern ~r/^### ([A-Z0-9]+-A[0-9]+)/m
  @claimed_glob "test/**/*.exs"
  @claimed_pattern ~r/action:\s*"([A-Z0-9]+-A[0-9]+)"/

  @impl Mix.Task
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: [feature: :string, exitcode: :boolean])

    result = report(feature: opts[:feature])
    print(result)

    if opts[:exitcode] && uncovered?(result) do
      System.halt(1)
    end
  end

  @doc """
  Computes the coverage report without printing or halting anything — the
  function the task's own tests call directly.

  Accepts `:requirements_glob` and `:claimed_glob` overrides (beyond the real
  `--feature` CLI option), purely so this task's own tests can point at fixed
  fixtures instead of the real, ever-growing `docs/requirements/` and `test/`
  trees — every real invocation uses the defaults.

  Returns `%{feature:, defined:, claimed:, covered:, uncovered:,
  claimed_but_undefined:}`, each of the set fields a `MapSet` of action ID
  strings.
  """
  @spec report(keyword()) :: %{
          feature: String.t() | nil,
          defined: MapSet.t(String.t()),
          claimed: MapSet.t(String.t()),
          covered: MapSet.t(String.t()),
          uncovered: MapSet.t(String.t()),
          claimed_but_undefined: MapSet.t(String.t())
        }
  def report(opts \\ []) do
    feature = Keyword.get(opts, :feature)
    requirements_glob = Keyword.get(opts, :requirements_glob, @requirements_glob)
    claimed_glob = Keyword.get(opts, :claimed_glob, @claimed_glob)

    all_defined = defined_action_ids(requirements_glob)
    all_claimed = claimed_action_ids(claimed_glob)

    defined = filter_feature(all_defined, feature)
    claimed = filter_feature(all_claimed, feature)

    %{
      feature: feature,
      defined: defined,
      claimed: claimed,
      covered: MapSet.intersection(defined, claimed),
      uncovered: MapSet.difference(defined, claimed),
      claimed_but_undefined: MapSet.difference(claimed, all_defined)
    }
  end

  @doc """
  Whether `report/1`'s result has anything uncovered — the decision
  `--exitcode` acts on.
  """
  @spec uncovered?(map()) :: boolean()
  def uncovered?(%{uncovered: uncovered}), do: MapSet.size(uncovered) > 0

  @doc """
  Every action ID defined with a `### PREFIX-A##` header under the requirement
  pages matched by `glob` (`docs/requirements/*.md` by default), excluding
  `Home.md`'s worked example.
  """
  @spec defined_action_ids(String.t()) :: MapSet.t(String.t())
  def defined_action_ids(glob \\ @requirements_glob) do
    glob
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) == @excluded_requirement_file))
    |> extract_ids(@defined_pattern)
  end

  @doc """
  Every action ID claimed by an `@tag action: "PREFIX-A##"` in a file matched
  by `glob` (`test/**/*.exs` by default).
  """
  @spec claimed_action_ids(String.t()) :: MapSet.t(String.t())
  def claimed_action_ids(glob \\ @claimed_glob) do
    glob
    |> Path.wildcard()
    |> extract_ids(@claimed_pattern)
  end

  defp extract_ids(paths, pattern) do
    paths
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> then(&Regex.scan(pattern, &1, capture: :all_but_first))
      |> List.flatten()
    end)
    |> MapSet.new()
  end

  defp filter_feature(set, nil), do: set

  defp filter_feature(set, feature) do
    prefix = feature <> "-"
    MapSet.filter(set, &String.starts_with?(&1, prefix))
  end

  defp print(result) do
    scope = if result.feature, do: " (--feature #{result.feature})", else: ""

    Mix.shell().info("""

    mix nucleus.trace#{scope}

    Defined:              #{MapSet.size(result.defined)}
    Covered:               #{MapSet.size(result.covered)}
    Uncovered:             #{MapSet.size(result.uncovered)}
    Claimed but undefined: #{MapSet.size(result.claimed_but_undefined)}
    """)

    print_ids("Uncovered", result.uncovered)
    print_ids("Claimed but undefined", result.claimed_but_undefined)
  end

  defp print_ids(label, set) do
    if MapSet.size(set) > 0 do
      ids = set |> Enum.sort() |> Enum.map(&"  - #{&1}") |> Enum.join("\n")
      Mix.shell().info("#{label}:\n#{ids}\n")
    end
  end
end
