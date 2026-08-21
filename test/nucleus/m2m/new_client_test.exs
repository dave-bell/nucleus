defmodule Nucleus.M2M.NewClientTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Nucleus.M2M.NewClient

  describe "changeset/2 — M2M-A05 ticket ID errors, one distinct message per reason" do
    @tag action: "M2M-A05"
    @tag :unit
    test "an empty ticket ID reports 'can't be blank', not TicketId's own :empty message" do
      changeset = NewClient.changeset(%NewClient{}, %{"purpose" => "nightly-sync"})

      refute changeset.valid?
      assert %{ticket_id: [message]} = errors_on(changeset)
      assert message == "can't be blank"
    end

    @tag action: "M2M-A05"
    @tag :unit
    test "the wrong case (lowercase prefix) reports a format-specific message" do
      changeset =
        NewClient.changeset(%NewClient{}, %{"ticket_id" => "ops-1234", "purpose" => "sync"})

      refute changeset.valid?
      assert %{ticket_id: [message]} = errors_on(changeset)
      assert message =~ "OPS-1234"
    end

    @tag action: "M2M-A05"
    @tag :unit
    test "a 21-character ticket ID reports a length-specific message, distinct from the format one" do
      too_long = "OPS-" <> String.duplicate("1", 17)

      changeset =
        NewClient.changeset(%NewClient{}, %{"ticket_id" => too_long, "purpose" => "sync"})

      refute changeset.valid?
      assert %{ticket_id: [message]} = errors_on(changeset)
      assert message =~ "20"
      refute message =~ "OPS-1234"
    end
  end

  describe "changeset/2 — M2M-A06 purpose errors, one distinct message per reason" do
    @tag action: "M2M-A06"
    @tag :unit
    test "an empty purpose reports 'can't be blank', not Purpose's own :empty message" do
      changeset = NewClient.changeset(%NewClient{}, %{"ticket_id" => "OPS-1234"})

      refute changeset.valid?
      assert %{purpose: [message]} = errors_on(changeset)
      assert message == "can't be blank"
    end

    @tag action: "M2M-A06"
    @tag :unit
    test "a leading hyphen reports a message distinct from a charset violation" do
      leading =
        NewClient.changeset(%NewClient{}, %{"ticket_id" => "OPS-1234", "purpose" => "-sync"})

      charset =
        NewClient.changeset(%NewClient{}, %{
          "ticket_id" => "OPS-1234",
          "purpose" => "Nightly-Sync"
        })

      refute leading.valid?
      refute charset.valid?

      assert %{purpose: [leading_message]} = errors_on(leading)
      assert %{purpose: [charset_message]} = errors_on(charset)

      assert leading_message =~ "start"
      assert charset_message =~ "lowercase"
      refute leading_message == charset_message
    end

    @tag action: "M2M-A06"
    @tag :unit
    test "a trailing hyphen reports its own message" do
      changeset =
        NewClient.changeset(%NewClient{}, %{"ticket_id" => "OPS-1234", "purpose" => "sync-"})

      refute changeset.valid?
      assert %{purpose: [message]} = errors_on(changeset)
      assert message =~ "end"
    end

    @tag action: "M2M-A06"
    @tag :unit
    test "a 33-character purpose reports a length-specific message" do
      too_long = String.duplicate("a", 33)

      changeset =
        NewClient.changeset(%NewClient{}, %{"ticket_id" => "OPS-1234", "purpose" => too_long})

      refute changeset.valid?
      assert %{purpose: [message]} = errors_on(changeset)
      assert message =~ "32"
    end
  end

  describe "changeset/2 — a valid pair" do
    @tag action: "M2M-A05"
    @tag :unit
    test "produces a valid changeset, both fields readable via get_field/2" do
      changeset =
        NewClient.changeset(%NewClient{}, %{
          "ticket_id" => "OPS-1234",
          "purpose" => "nightly-sync"
        })

      assert changeset.valid?
      assert Changeset.get_field(changeset, :ticket_id) == "OPS-1234"
      assert Changeset.get_field(changeset, :purpose) == "nightly-sync"
    end

    @tag :unit
    test "the access token validity field defaults to 15 minutes when omitted" do
      changeset =
        NewClient.changeset(%NewClient{}, %{
          "ticket_id" => "OPS-1234",
          "purpose" => "nightly-sync"
        })

      assert Changeset.get_field(changeset, :access_token_validity_minutes) == 15
    end

    @tag :unit
    test "default_token_validity_minutes/0 matches the schema default" do
      assert NewClient.default_token_validity_minutes() == 15
    end
  end

  describe "changeset/2 — an input violating two rules is deterministic" do
    @tag :unit
    test "a too-long, wrong-case ticket ID always reports the same reason" do
      bad = "ops-" <> String.duplicate("1", 30)

      changeset1 = NewClient.changeset(%NewClient{}, %{"ticket_id" => bad, "purpose" => "sync"})
      changeset2 = NewClient.changeset(%NewClient{}, %{"ticket_id" => bad, "purpose" => "sync"})

      assert errors_on(changeset1) == errors_on(changeset2)
    end
  end

  defp errors_on(changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
