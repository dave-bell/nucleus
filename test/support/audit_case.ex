defmodule Nucleus.AuditCase do
  @moduledoc """
  Assertions over `Nucleus.Audit.emit/2` records, for any test that needs to
  prove an audit event was (or was not) written.

  `config/test.exs` already configures `Nucleus.Audit`'s `:sink` as
  `Nucleus.Audit.Sink.Test`. This case only needs to `register/1` the current
  test process before each test, and give tests a vocabulary for asserting on
  what arrives.

  `Nucleus.Audit.Sink.Test.register/1` stores the receiving pid in the
  *calling* process's dictionary (see its moduledoc), so registration here is
  `async: true` safe — unlike `Nucleus.BackendCase`, nothing here touches
  global state.

      defmodule MyTest do
        use Nucleus.AuditCase, async: true

        test "..." do
          Nucleus.Audit.emit(:secret_viewed, tenant: "acme", resource: "/prod/API_KEY")

          assert_audit_event(:secret_viewed, resource: "/prod/API_KEY")
          refute_audit_contains("shh")
        end
      end
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias Nucleus.Audit.Sink

  @events_key :nucleus_audit_case_raw_events

  using do
    quote do
      import Nucleus.AuditCase
    end
  end

  setup do
    Sink.Test.register(self())
    :ok
  end

  @doc """
  Every audit record emitted so far in this test, oldest first, decoded from
  the sink's raw `{:audit, binary}` messages.

  Safe to call more than once — each call drains any new messages from the
  mailbox and merges them with what a previous call already saw, so ordering
  and exactly-once assertions both hold regardless of how many times a test
  calls this.
  """
  @spec audit_events() :: [map()]
  def audit_events do
    raw_events() |> Enum.map(&decode/1)
  end

  @doc """
  Asserts exactly one emitted record matches `event`, and — when given —
  that its fields match `fields`.

  `fields` may name any top-level field (`:user`, `:tenant`, `:resource`,
  `:reason`, `:source_ip`) for an exact match, or `:details` for a **subset**
  match against the record's `details` map (so a test only names the detail
  keys it cares about).

      assert_audit_event(:secret_viewed, tenant: "acme", resource: "/prod/API_KEY")
      assert_audit_event(:nomad_var_updated, details: %{key: "FEATURE_FLAG"})

  Fails with the full list of emitted events when there is no match, so a
  failure shows what was actually recorded rather than just "not found".
  """
  @spec assert_audit_event(atom(), keyword() | map()) :: map()
  def assert_audit_event(event, fields \\ %{}) when is_atom(event) do
    fields = Map.new(fields)
    events = audit_events()

    case Enum.find(events, &matches?(&1, event, fields)) do
      nil ->
        flunk("""
        expected an audit event #{inspect(event)} matching #{inspect(fields)}.

        Emitted events:
        #{inspect(events, pretty: true)}
        """)

      record ->
        record
    end
  end

  @doc """
  Asserts no emitted record is for `event`, regardless of its fields.
  """
  @spec assert_no_audit_event(atom()) :: :ok
  def assert_no_audit_event(event) when is_atom(event) do
    events = audit_events()

    if Enum.any?(events, &(&1.event == event)) do
      flunk("""
      expected no audit event #{inspect(event)}, but found one.

      Emitted events:
      #{inspect(events, pretty: true)}
      """)
    end

    :ok
  end

  @doc """
  Asserts `value` appears in **no** emitted record — the reusable AUD-A02
  guard: a secret value must never reach the audit trail.

  Checked against each record's raw encoded form (before decoding), so it
  catches `value` regardless of which top-level field or detail key it might
  have leaked into — the point is that it must not be anywhere, not that it
  must be absent from a field this helper happened to enumerate.
  """
  @spec refute_audit_contains(String.t()) :: :ok
  def refute_audit_contains(value) when is_binary(value) do
    raw = raw_events()

    if Enum.any?(raw, &String.contains?(&1, value)) do
      flunk("""
      expected #{inspect(value)} to appear in no emitted audit record, but found it.

      Emitted events:
      #{inspect(Enum.map(raw, &decode/1), pretty: true)}
      """)
    end

    :ok
  end

  defp raw_events do
    cached = Process.get(@events_key, [])
    new = drain()
    updated = cached ++ new
    Process.put(@events_key, updated)
    updated
  end

  defp drain do
    receive do
      {:audit, binary} -> [binary | drain()]
    after
      0 -> []
    end
  end

  defp decode(binary) do
    binary
    |> String.trim_trailing("\n")
    |> Jason.decode!()
    |> atomize_keys()
    |> Map.update!(:event, &String.to_existing_atom/1)
  end

  defp atomize_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {String.to_existing_atom(key), atomize_keys(value)} end)
  end

  defp atomize_keys(other), do: other

  defp matches?(record, event, fields) do
    record.event == event and Enum.all?(fields, &field_matches?(record, &1))
  end

  defp field_matches?(record, {:details, expected}) when is_map(expected) do
    expected = Map.new(expected)
    Map.take(record.details, Map.keys(expected)) == expected
  end

  defp field_matches?(record, {key, expected}), do: Map.get(record, key) == expected
end
