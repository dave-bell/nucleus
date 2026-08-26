defmodule NucleusWeb.SidebarNavStateTest do
  use ExUnit.Case, async: true

  alias NucleusWeb.SidebarNavState

  # Real random ids, not tiny sequential ones — this test runs against the
  # single process the application supervises (there is nothing to isolate
  # per-test the way `Nucleus.Backend.Seed` supports a distinct `name:`),
  # so distinct keys are what keep tests from ever touching one another's
  # data, `async: true` included.
  defp session_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16))

  test "get/1 defaults to an empty set for a session that has never toggled anything" do
    assert SidebarNavState.get(session_id()) == MapSet.new()
  end

  test "toggle/2 adds an absent category and returns the resulting set" do
    session = session_id()

    assert SidebarNavState.toggle(session, "regulated") == MapSet.new(["regulated"])
  end

  test "toggle/2 removes a present category and returns the resulting set" do
    session = session_id()

    SidebarNavState.toggle(session, "regulated")

    assert SidebarNavState.toggle(session, "regulated") == MapSet.new()
  end

  test "a later get/1 reflects a prior toggle/2 — the state a remount reads back" do
    session = session_id()

    SidebarNavState.toggle(session, "pre-production")

    assert SidebarNavState.get(session) == MapSet.new(["pre-production"])
  end

  test "two categories toggled independently for the same session both persist" do
    session = session_id()

    SidebarNavState.toggle(session, "regulated")
    SidebarNavState.toggle(session, "experimental")

    assert SidebarNavState.get(session) == MapSet.new(["regulated", "experimental"])
  end

  test "two sessions never see one another's expanded categories" do
    session_a = session_id()
    session_b = session_id()

    SidebarNavState.toggle(session_a, "regulated")

    assert SidebarNavState.get(session_a) == MapSet.new(["regulated"])
    assert SidebarNavState.get(session_b) == MapSet.new()
  end

  # The whole reason `toggle/2` is a `GenServer.call/2` rather than a
  # `get/1` + precomputed `:ets.insert/2` from the caller: two concurrent
  # toggles of the *same* slug for the *same* session must never both read
  # the same starting state and independently compute the same result,
  # which would silently lose one of the two flips. Firing an odd count of
  # concurrent toggles and asserting the category ends up present (an even
  # count would end up absent) only holds if every single flip was actually
  # applied — a lost update would desync the final parity from the count.
  test "concurrent toggles of the same slug for the same session never lose an update" do
    session = session_id()
    concurrent_toggles = 41

    1..concurrent_toggles
    |> Task.async_stream(fn _ -> SidebarNavState.toggle(session, "regulated") end,
      max_concurrency: concurrent_toggles,
      timeout: 5_000
    )
    |> Stream.run()

    assert SidebarNavState.get(session) == MapSet.new(["regulated"])
  end
end
