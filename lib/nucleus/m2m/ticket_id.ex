defmodule Nucleus.M2M.TicketId do
  @moduledoc """
  Shape validation for the ticket ID half of an M2M client name
  (`{tenant}-control-plane-{ticket_id}-{purpose}`).

  Pure — no I/O, cannot be skipped by a network fault, and cheap enough to
  run before anything else, matching `Nucleus.Environments.validate_name/1`'s
  role in `SEC-S1`'s ladder. `Nucleus.M2M.fetch/2` does not call this module
  directly (a client ID and a ticket ID are different values — see
  `Nucleus.M2M.ClientId`), but the M2M-S4 creation form does, before
  `Nucleus.M2M.ClientName.build/2` ever concatenates one into a name.

  ## Anchored, allowlist, uppercase-only — all deliberate

  The pattern is `[A-Z]+-\\d+`, **anchored** (`\\A...\\z`). Unanchored,
  `"OPS-1234; DROP"` would match — anchoring is the whole point of the
  regex, not an incidental detail.

  Case is not normalised. `"ops-1234"` is rejected, not silently upcased —
  silently accepting and rewriting input the requirement describes as
  invalid would mean `M2M-A07`'s live preview shows a client name built from
  a ticket ID the user did not actually type.

  ## Distinct reason atoms, not one generic message

  `M2M-A05` requires the creation form to indicate the *specific* problem, so
  a single `:invalid` atom cannot carry the difference between "wrong shape"
  and "too long." Checked in a fixed order — empty, then too long, then
  format — so an input violating more than one rule always reports the same
  reason, deterministically.
  """

  @max_length 20
  @pattern ~r/\A[A-Z]+-\d+\z/

  @type reason :: :empty | :too_long | :format

  @doc """
  The maximum number of characters a ticket ID may contain.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Validates `ticket_id`'s shape: letters, a hyphen, then digits
  (`[A-Z]+-\\d+`, anchored), at most #{@max_length} characters.

  Accepts `term()`, not just `String.t()` — a ticket ID arriving from a
  client-controlled form param has not been shown to be a string yet.

      iex> Nucleus.M2M.TicketId.validate("OPS-1234")
      :ok

      iex> Nucleus.M2M.TicketId.validate("ops-1234")
      {:error, :format}

      iex> Nucleus.M2M.TicketId.validate("")
      {:error, :empty}

      iex> Nucleus.M2M.TicketId.validate(nil)
      {:error, :empty}
  """
  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(ticket_id) when is_binary(ticket_id) do
    cond do
      String.trim(ticket_id) == "" -> {:error, :empty}
      String.length(ticket_id) > @max_length -> {:error, :too_long}
      not Regex.match?(@pattern, ticket_id) -> {:error, :format}
      true -> :ok
    end
  end

  def validate(_not_a_binary), do: {:error, :empty}
end
