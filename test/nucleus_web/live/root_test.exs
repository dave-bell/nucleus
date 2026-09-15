defmodule NucleusWeb.RootTest do
  @moduledoc """
  `NAV-A01`: the application root (`/`) serves `NucleusWeb.ApplicationsLive`
  directly — no controller, no redirect hop (`router.ex`, `PageController`
  and its stock template deleted).

  `PhoenixTest.visit/2`, not `NucleusWeb.LiveCase`'s `live_applications/1`:
  `NAV-A01`'s `Then` clause names both the destination view and the shell
  chrome around it ("the user is taken directly to the Applications view ...
  the header and sidebar are visible"), which a plain `Phoenix.LiveViewTest`
  mount at `/` alone doesn't distinguish from mounting `/applications`
  directly — `visit/2` exercises the same `:browser`/`:assign_scope` request
  path a real browser hitting `/` would.
  """

  use NucleusWeb.ConnCase, async: false

  import PhoenixTest

  @tag :unit
  @tag action: "NAV-A01"
  test "visiting / lands on the Applications view, with the header and sidebar visible", %{
    conn: conn
  } do
    conn
    |> visit(~p"/")
    |> assert_has("#applications-table")
    |> assert_has("#sidebar")
    |> assert_has("#tenant-identifier")
  end
end
