defmodule NucleusWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures.

  Nucleus holds no local datastore, so there is no SQL sandbox to set up —
  see `docs/adr/0001-no-local-datastore.md`. Cases may safely run with
  `use NucleusWeb.ConnCase, async: true`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint NucleusWeb.Endpoint

      use NucleusWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import NucleusWeb.ConnCase
    end
  end

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
