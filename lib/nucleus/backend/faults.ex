defmodule Nucleus.Backend.Faults do
  @moduledoc """
  Optional latency and error injection for local backend implementations.

  Canned data is bad at exercising loading and error states — a local
  implementation that always succeeds instantly means the spinner and the
  "backend unavailable" branch are never seen, and their requirements are never
  testable. Two environment variables make a local implementation misbehave on
  demand:

  | Variable | Effect |
  |---|---|
  | `LOCAL_LATENCY_MS` | Sleep this many milliseconds before returning |
  | `LOCAL_FORCE_ERROR` | Return `{:error, %Error{kind: <this kind>}}` instead of succeeding |

  `LOCAL_FORCE_ERROR` takes any `Nucleus.Backend.Error` kind, e.g.
  `LOCAL_FORCE_ERROR=unavailable` or `LOCAL_FORCE_ERROR=auth_expired`.

  ## Usage

  A local implementation calls `maybe_fault/1` first in every callback and
  returns its result unchanged if it is not `:ok`:

      def list_environments(scope) do
        with :ok <- Faults.maybe_fault(:tenant_api) do
          {:ok, seeded_environments(scope)}
        end
      end

  Values are read from the environment on every call, deliberately: a developer
  can flip a fault on and off without restarting the server.

  Nothing gates this to non-production. It cannot fire unless a boundary is
  already running its local implementation, which `Nucleus.Backend` warns about
  loudly on boot.
  """

  alias Nucleus.Backend.Error

  @latency_var "LOCAL_LATENCY_MS"
  @error_var "LOCAL_FORCE_ERROR"

  @doc """
  Applies any configured fault for `boundary`.

  Returns `:ok` when no fault is configured, after sleeping for
  `LOCAL_LATENCY_MS` if that is set. Returns `{:error, Nucleus.Backend.Error.t()}`
  when `LOCAL_FORCE_ERROR` names a kind.

  Raises on an unparseable value for either variable. A typo in a fault flag
  must fail loudly — silently returning `:ok` would turn a test that meant to
  assert an error path into one that passes for the wrong reason.
  """
  @spec maybe_fault(atom()) :: :ok | {:error, Error.t()}
  def maybe_fault(boundary) when is_atom(boundary) do
    apply_latency()
    forced_error(boundary)
  end

  defp apply_latency do
    case System.get_env(@latency_var) do
      nil ->
        :ok

      "" ->
        :ok

      value ->
        case Integer.parse(value) do
          {ms, ""} when ms >= 0 ->
            Process.sleep(ms)
            :ok

          _ ->
            raise ArgumentError,
                  "#{@latency_var} must be a non-negative integer, got: #{inspect(value)}"
        end
    end
  end

  defp forced_error(boundary) do
    case System.get_env(@error_var) do
      nil ->
        :ok

      "" ->
        :ok

      value ->
        case Error.cast_kind(value) do
          {:ok, kind} ->
            {:error,
             Error.new(kind, boundary, "fault injected via #{@error_var}=#{value}", %{
               injected: true
             })}

          :error ->
            raise ArgumentError, """
            #{@error_var} must name a Nucleus.Backend.Error kind, got: #{inspect(value)}

            Valid kinds: #{Enum.map_join(Error.kinds(), ", ", &Atom.to_string/1)}.
            """
        end
    end
  end
end
