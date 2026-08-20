defmodule Nucleus.M2M.TokenValidity do
  @moduledoc """
  Humanises `Nucleus.M2M.ClientDetail.token_validity_seconds` for display
  (`M2M-A16`).

  A pure function, its own module, unit-tested — the singular case ("1
  hour", not "1 hours") is exactly the kind of detail that gets refactored
  into a single interpolated plural by someone tidying a template later.
  Deliberately not `ngettext`/`Gettext`: this app has no active
  translations, and `M2M-A16` describes English pluralisation of one field,
  not localisation.

  ## Largest exact unit wins

  `docs/requirements/M2M-Clients.md`'s `M2M-A16`: a whole number of hours
  reads in hours, else a whole number of minutes reads in minutes, else it
  reads in seconds. This is a three-tier rule, not the two-tier
  hours-only rule an earlier draft of this ticket's plan described —
  `token_validity_seconds` (not `token_validity_hours`) is the field this
  reads, per `Nucleus.M2M.ClientDetail` and EN-10 / #33.

  Cognito's own `AccessTokenValidity` + `TokenValidityUnits` can express a
  value in seconds, minutes, hours, or days; `Nucleus.M2M.Clients.Cognito`
  normalises all of that to seconds before this ever sees it
  (`lib/nucleus/m2m/clients/cognito.ex:256-271`). A value that arrived in a
  non-hours unit (say, a Terraform-managed client set to `450` seconds) is
  exactly the case that proves this function and that normalisation compose:
  `450` is not a whole number of minutes (`450 / 60 = 7.5`), so it falls
  through to the seconds tier and reads `"450 seconds"`, not `"0 hours"` or
  a crash.
  """

  @doc """
  Humanises `seconds` into its largest exact unit, singular at exactly `1`.

  `nil` yields a neutral "not set" rather than `"nil hours"` or a crash — a
  client this feature didn't create can, in principle, arrive with no
  reliable value to show.

      iex> Nucleus.M2M.TokenValidity.humanize(3600)
      "1 hour"

      iex> Nucleus.M2M.TokenValidity.humanize(7200)
      "2 hours"

      iex> Nucleus.M2M.TokenValidity.humanize(60)
      "1 minute"

      iex> Nucleus.M2M.TokenValidity.humanize(900)
      "15 minutes"

      iex> Nucleus.M2M.TokenValidity.humanize(1)
      "1 second"

      iex> Nucleus.M2M.TokenValidity.humanize(450)
      "450 seconds"

      iex> Nucleus.M2M.TokenValidity.humanize(nil)
      "not set"
  """
  @spec humanize(seconds :: pos_integer() | nil) :: String.t()
  def humanize(nil), do: "not set"

  def humanize(seconds) when is_integer(seconds) and seconds > 0 do
    cond do
      rem(seconds, 3600) == 0 -> pluralize(div(seconds, 3600), "hour")
      rem(seconds, 60) == 0 -> pluralize(div(seconds, 60), "minute")
      true -> pluralize(seconds, "second")
    end
  end

  defp pluralize(1, unit), do: "1 #{unit}"
  defp pluralize(n, unit), do: "#{n} #{unit}s"
end
