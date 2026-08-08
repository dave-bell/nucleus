defmodule Nucleus.Backend.Error do
  @moduledoc """
  The one error value every backend boundary is allowed to return.

  Backend implementations translate whatever their underlying system raises —
  an `ExAws` tuple, a `Req.TransportError`, an HTTP 500 body — into this struct
  and return it as `{:error, %Nucleus.Backend.Error{}}`. Callers pattern-match
  on `kind` to decide what to show the user.

  **These are returned, never raised.** A `rescue` inside a `handle_event/3` is
  not an acceptable control-flow mechanism, and a LiveView that had to rescue a
  backend-specific exception would be coupled to that backend — the exact
  coupling `Nucleus.Backend` exists to prevent.

  ## Kinds

  The six kinds cover the failure modes the requirements describe. Requirement
  status codes are binding as *behaviour*, not as literal HTTP responses (see
  `business-tech-bridge.md`), so each kind carries the meaning rather than the
  number.

  | `kind` | Meaning | Requirement status code |
  |---|---|---|
  | `:invalid` | Caller-supplied input rejected before any backend call | 400 |
  | `:not_found` | Well-formed identifier, no such resource | 404 |
  | `:already_exists` | Create conflicted with an existing resource | 409 |
  | `:auth_expired` | Server-side credentials for the backend expired | 401 |
  | `:unavailable` | Backend unreachable, timed out, or errored | 503 / 502 |
  | `:not_configured` | This boundary has no usable configuration | 503 |

  `:auth_expired` is about *Nucleus's* credentials for a backend (an expired
  assumed role, say), not about the end user's session. Adding a seventh kind
  means revisiting every `case` that matches on one, which is what
  `kinds/0` and its test exist to force.
  """

  @kinds [:not_found, :already_exists, :auth_expired, :unavailable, :not_configured, :invalid]

  @type kind ::
          :not_found | :already_exists | :auth_expired | :unavailable | :not_configured | :invalid

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          boundary: atom(),
          details: map()
        }

  @enforce_keys [:kind, :message, :boundary]
  defstruct [:kind, :message, :boundary, details: %{}]

  @doc """
  Every valid `kind`, so a test can assert exhaustive handling.

      iex> :not_found in Nucleus.Backend.Error.kinds()
      true
  """
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Builds an error for `boundary`.

  `message` is developer-facing and may be logged; it must never contain secret
  material. `details` carries structured context (a key, a path, an upstream
  status) for logging and audit.

      iex> error = Nucleus.Backend.Error.new(:not_found, :secrets, "no such parameter")
      iex> {error.kind, error.boundary, error.message, error.details}
      {:not_found, :secrets, "no such parameter", %{}}
  """
  @spec new(kind(), atom(), String.t(), map()) :: t()
  def new(kind, boundary, message, details \\ %{})
      when kind in @kinds and is_atom(boundary) and is_binary(message) and is_map(details) do
    %__MODULE__{kind: kind, message: message, boundary: boundary, details: details}
  end

  @doc """
  Casts an external string (an env var, a query param) to a `kind`.

  Returns `:error` for anything unrecognised rather than guessing. Deliberately
  avoids `String.to_atom/1` — this takes untrusted input.

      iex> Nucleus.Backend.Error.cast_kind("auth_expired")
      {:ok, :auth_expired}

      iex> Nucleus.Backend.Error.cast_kind("teapot")
      :error
  """
  @spec cast_kind(String.t()) :: {:ok, kind()} | :error
  def cast_kind(value) when is_binary(value) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == value)) do
      nil -> :error
      kind -> {:ok, kind}
    end
  end
end
