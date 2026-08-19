defmodule Nucleus.Secrets.Value do
  @moduledoc """
  Shape validation for a secret's plaintext value — `SEC-A06`'s edit path and
  `SEC-A09`'s creation path (`SEC-S6`) share this module rather than each
  keeping its own copy; whichever ticket lands first builds it.

  Per the wiki's API contract (`value (≤4096 chars)`) and `SEC-A11`: a value
  must be non-empty and no more than 4096 characters.

  ## Characters, not bytes

  Length is checked with `String.length/1`, never `byte_size/1`. The
  requirement says "4096 characters" and `SEC-A11` asks for "a live running
  count of characters used" — counting bytes would fail a multi-byte value
  (a signing key with non-ASCII content, say) at a length that looks wrong to
  the person who typed it, since one visible character can be several bytes.

  ## Returns a `Nucleus.Backend.Error`, not a bare atom or string

  Callers on both the create and update paths already handle
  `Nucleus.Backend.Error.t()` from every other validation step
  (`Nucleus.Environments.fetch/2`, the key-shape check) — returning the same
  shape here means one `case`/`with` chain handles all three without a
  special branch for value errors. `kind: :invalid` matches the meaning
  `Nucleus.Backend.Error`'s moduledoc gives that kind: "caller-supplied input
  rejected before any backend call." `boundary` is `:secrets`
  (`Nucleus.Secrets.Store.boundary/0`) since this is a `:secrets`-domain
  shape rule, not a generic one.
  """

  alias Nucleus.Backend.Error
  alias Nucleus.Secrets.Store

  @max_length 4096

  @doc """
  The maximum number of characters a secret value may contain.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Validates `value`'s shape: non-empty, at most #{@max_length} characters.

  Accepts `term()`, not just `String.t()` — a value arriving from a
  client-controlled form param has not been shown to be a string yet, and
  rejecting a non-binary as `:invalid` here is simpler than a `FunctionClauseError`
  reaching a caller that forgot to guard first.

      iex> Nucleus.Secrets.Value.validate("s3cr3t")
      :ok

      iex> {:error, error} = Nucleus.Secrets.Value.validate("")
      iex> error.kind
      :invalid

      iex> {:error, error} = Nucleus.Secrets.Value.validate(String.duplicate("a", 4097))
      iex> error.kind
      :invalid
  """
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(value) when is_binary(value) do
    cond do
      value == "" ->
        {:error, invalid("secret value must not be empty")}

      String.length(value) > @max_length ->
        {:error,
         invalid("secret value exceeds #{@max_length} characters", %{
           length: String.length(value)
         })}

      true ->
        :ok
    end
  end

  def validate(other) do
    {:error, invalid("secret value must be a string", %{value: inspect(other)})}
  end

  defp invalid(message, details \\ %{}) do
    Error.new(:invalid, Store.boundary(), message, details)
  end
end
