defmodule NucleusWeb.M2MClientsLive.Format do
  @moduledoc """
  Shared, pure display formatting for `NucleusWeb.M2MClientsLive.Index` and
  `.Show` — both need `created_date` rendered the same way, and per issue
  #35's Decision 7 ("two modules can't share markup by accident"), a
  formatter both call is a real shared module, not two independently
  maintained private helpers that can silently drift apart.
  """

  @doc """
  Formats a client's `created_date` for display.

  `Index` never calls the `nil` clause today — a `Nucleus.M2M.Client` row
  whose per-client describe failed while listing carries
  `created_date_error` instead, and `Index` takes its own dedicated
  `#m2m-client-date-unavailable-{id}` branch for that case rather than
  rendering this function's `nil` output. `Show`'s
  `Nucleus.M2M.ClientDetail.created_date` has no equivalent per-field error
  kind, so a client this feature didn't create (no `AccessTokenValidity` set,
  say) can still arrive with `created_date: nil`; this clause is `Show`'s
  only defence against rendering `"nil"` or crashing on that case.

      iex> NucleusWeb.M2MClientsLive.Format.created_date(~U[2026-05-01 09:00:00Z])
      "2026-05-01 09:00 UTC"

      iex> NucleusWeb.M2MClientsLive.Format.created_date(nil)
      "unavailable"
  """
  @spec created_date(DateTime.t() | nil) :: String.t()
  def created_date(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  def created_date(nil), do: "unavailable"
end
