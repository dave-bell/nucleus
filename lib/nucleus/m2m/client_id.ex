defmodule Nucleus.M2M.ClientId do
  @moduledoc """
  Shape validation for a Cognito App Client's `client_id` — the identifier
  `M2M-A13` requires be rejected, before any lookup, when malformed.

  Pure, allowlist-based, matching `Nucleus.Environments.validate_name/1`'s
  reasoning (`SEC-S1`'s equivalent gate): a positive charset check rejects
  path traversal, injection, and hostile encodings by construction, rather
  than trying to enumerate what to reject.

  ## AWS's own pattern, not a tighter one — M2M-S1 Decision 5

  The pattern is `~r/\\A[A-Za-z0-9_+]{1,128}\\z/`, anchored — AWS's own
  documented `ClientId` shape (`[\\w+]+`, 1–128 characters), **not** the
  tighter `~r/\\A[a-z0-9]{1,128}\\z/` or the exact
  `~r/\\A[a-z0-9]{26}\\z/` this ticket's body originally considered. Real
  Cognito client IDs observed so far are 26 lowercase alphanumerics, but
  that is an observation of one pool, not a contract AWS documents anywhere.
  Widening to uppercase, `_`, and `+` costs nothing: a well-formed-but-
  nonexistent ID already returns `:not_found` from one `describe_client/1`
  call, while guessing the format too tight risks a total feature outage —
  every existing client 400s — until a deploy. See
  [Decision 5](https://github.com/dave-bell/nucleus/issues/34#issuecomment-5350434771).

  This is still an anchored allowlist: `..`, `/`, `\\`, null bytes,
  whitespace, unicode lookalikes, and percent-encoding are all rejected by
  construction, since none of those characters are in `[A-Za-z0-9_+]`.
  """

  alias Nucleus.Backend.Error

  @boundary :m2m
  @max_length 128
  @pattern ~r/\A[A-Za-z0-9_+]{1,#{@max_length}}\z/

  @doc """
  The maximum number of characters a client ID may contain.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Validates `client_id`'s shape against AWS's own `ClientId` pattern.

  Pure — performs no I/O and calls no adapter. Returns `:ok` or
  `{:error, %Nucleus.Backend.Error{kind: :invalid}}`. Accepts `term()`, not
  just `String.t()` — a client ID arriving from a URL path segment has not
  been shown to be a string yet.

      iex> Nucleus.M2M.ClientId.validate("4f2a9c1e7b3d8f0a1c2e3f4a5b6c7d8e")
      :ok

      iex> {:error, error} = Nucleus.M2M.ClientId.validate("../etc")
      iex> error.kind
      :invalid

      iex> {:error, error} = Nucleus.M2M.ClientId.validate(nil)
      iex> error.kind
      :invalid
  """
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(client_id) when is_binary(client_id) do
    if Regex.match?(@pattern, client_id) do
      :ok
    else
      invalid(client_id)
    end
  end

  def validate(client_id), do: invalid(client_id)

  defp invalid(client_id) do
    {:error,
     Error.new(:invalid, @boundary, "invalid client ID", %{client_id: inspect(client_id)})}
  end
end
