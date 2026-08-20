defmodule Nucleus.M2M.Purpose do
  @moduledoc """
  Shape validation for the purpose half of an M2M client name
  (`{tenant}-control-plane-{ticket_id}-{purpose}`).

  Pure, matching `Nucleus.M2M.TicketId`'s role and reasoning — see that
  module's doc for why this is a separate concern from
  `Nucleus.M2M.ClientId` (the *resulting* client's identifier, not an input
  to building its name).

  ## Hyphen placement gets its own reasons

  `M2M-A06` calls out leading/trailing hyphen placement separately from the
  charset rule, and "purpose cannot start with a hyphen" is far more
  actionable form feedback than "purpose contains invalid characters" — so
  `:leading_hyphen` and `:trailing_hyphen` are distinct from `:charset`,
  checked in a fixed order (empty, too long, charset, leading hyphen,
  trailing hyphen) so a purpose violating more than one rule always reports
  the same reason, deterministically.

  A double hyphen (`"nightly--sync"`) is accepted — `[a-z0-9-]+` allows it,
  and the requirement only forbids leading/trailing hyphens, not internal
  runs of them. Tightening beyond that is a rule this module does not add.
  """

  @max_length 32
  @charset ~r/\A[a-z0-9-]+\z/

  @type reason :: :empty | :too_long | :charset | :leading_hyphen | :trailing_hyphen

  @doc """
  The maximum number of characters a purpose may contain.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Validates `purpose`'s shape: lowercase letters, digits, and hyphens only
  (`[a-z0-9-]+`), no leading or trailing hyphen, at most #{@max_length}
  characters.

  Accepts `term()`, not just `String.t()` — a purpose arriving from a
  client-controlled form param has not been shown to be a string yet.

      iex> Nucleus.M2M.Purpose.validate("nightly-sync")
      :ok

      iex> Nucleus.M2M.Purpose.validate("-sync")
      {:error, :leading_hyphen}

      iex> Nucleus.M2M.Purpose.validate("Nightly-Sync")
      {:error, :charset}

      iex> Nucleus.M2M.Purpose.validate(nil)
      {:error, :empty}
  """
  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(purpose) when is_binary(purpose) do
    cond do
      String.trim(purpose) == "" -> {:error, :empty}
      String.length(purpose) > @max_length -> {:error, :too_long}
      not Regex.match?(@charset, purpose) -> {:error, :charset}
      String.starts_with?(purpose, "-") -> {:error, :leading_hyphen}
      String.ends_with?(purpose, "-") -> {:error, :trailing_hyphen}
      true -> :ok
    end
  end

  def validate(_not_a_binary), do: {:error, :empty}
end
