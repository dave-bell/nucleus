defmodule Nucleus.M2M.TicketIdTest do
  use ExUnit.Case, async: true

  alias Nucleus.M2M.TicketId

  describe "validate/1 — M2M-A05 shape" do
    @tag :unit
    test "accepts well-formed ticket IDs" do
      for ticket_id <- ["OPS-1234", "A-1", "SUPPORT-99999", String.duplicate("A", 17) <> "-1"] do
        assert TicketId.validate(ticket_id) == :ok
      end
    end

    @tag :unit
    test "accepts a ticket ID exactly at the 20-character boundary" do
      ticket_id = "OPS-" <> String.duplicate("1", 16)
      assert String.length(ticket_id) == 20
      assert TicketId.validate(ticket_id) == :ok
    end

    @tag :unit
    test "rejects a ticket ID one character past the 20-character boundary" do
      ticket_id = "OPS-" <> String.duplicate("1", 17)
      assert String.length(ticket_id) == 21
      assert TicketId.validate(ticket_id) == {:error, :too_long}
    end

    @tag :unit
    test "rejects empty, whitespace-only, and non-binary input as :empty" do
      for input <- ["", "   ", nil, :ops] do
        assert TicketId.validate(input) == {:error, :empty}
      end
    end

    @tag :unit
    test "rejects malformed shapes as :format" do
      malformed = [
        "ops-1234",
        "OPS1234",
        "OPS-",
        "-1234",
        "OPS-12a4",
        "OPS-1234; DROP",
        "OPS-1234\n",
        "OPS-1234-EXTRA"
      ]

      for ticket_id <- malformed do
        assert TicketId.validate(ticket_id) == {:error, :format}
      end
    end

    @tag :unit
    test "anchoring rejects trailing junk after a valid shape" do
      assert TicketId.validate("OPS-1234; DROP") == {:error, :format}
      assert TicketId.validate("OPS-1234\n") == {:error, :format}
    end
  end
end
