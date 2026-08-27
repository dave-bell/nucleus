defmodule Nucleus.NomadVars.Value do
  @moduledoc """
  Shape validation for a Nomad Variable's value — `DEX-A05`'s edit path and
  the wiki's `PUT /api/nomad/variables/{key}` contract row (`value (≤4096
  chars)`).

  Sibling of `Nucleus.Secrets.Value`, not a reuse across boundaries —
  different domain, same rule shape (non-empty, `@max_length` characters,
  counted with `String.length/1` rather than `byte_size/1`, matching
  `Secrets.Value`'s reasoning: a multi-byte character at the boundary must
  count as one character, not several bytes).

  ## Distinct reason atoms, not a single `:invalid`

  Returns a bare atom (`:empty`, `:too_long`), not a `Nucleus.Backend.Error` —
  the same shape `Nucleus.M2M.Purpose.validate/1` and `Nucleus.M2M.TicketId`
  give their own per-rule reasons (M2M-S1's rationale: distinct reasons make
  more actionable caller-facing copy than a single collapsed `:invalid`
  would). Wrapping into a `Nucleus.Backend.Error{kind: :invalid}` — with
  whatever `field`/`key` context is available — is the calling context
  module's job (a future `Nucleus.NomadVars` module, DEX-S2/DEX-S4), the same
  division of labour `Nucleus.M2M.create_client/2` already draws around
  `Purpose.validate/1`.
  """

  @max_length 4096

  @type reason :: :empty | :too_long

  @doc """
  The maximum number of characters a variable value may contain.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Validates `value`'s shape: non-empty, at most #{@max_length} characters.

  Accepts `term()`, not just `String.t()` — a value arriving from a
  client-controlled form param has not been shown to be a string yet.

      iex> Nucleus.NomadVars.Value.validate("prod,staging")
      :ok

      iex> Nucleus.NomadVars.Value.validate("")
      {:error, :empty}

      iex> Nucleus.NomadVars.Value.validate(String.duplicate("a", 4097))
      {:error, :too_long}

      iex> Nucleus.NomadVars.Value.validate(nil)
      {:error, :empty}
  """
  @spec validate(term()) :: :ok | {:error, reason()}
  def validate(value) when is_binary(value) do
    cond do
      value == "" -> {:error, :empty}
      String.length(value) > @max_length -> {:error, :too_long}
      true -> :ok
    end
  end

  def validate(_not_a_binary), do: {:error, :empty}
end
