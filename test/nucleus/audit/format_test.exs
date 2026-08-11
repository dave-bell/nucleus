defmodule Nucleus.Audit.FormatTest do
  use ExUnit.Case, async: true

  alias Nucleus.Audit.Event
  alias Nucleus.Audit.Format

  doctest Format

  defp event(overrides \\ %{}) do
    struct(
      %Event{
        event: :secret_viewed,
        user: "alice",
        tenant: "acme",
        timestamp: ~U[2026-08-11 12:34:56Z],
        source_ip: "203.0.113.7",
        resource: "acme/prod/api-key",
        reason: nil,
        details: %{}
      },
      overrides
    )
  end

  describe "encode/2 with :json" do
    @tag :unit
    test "is a single newline-terminated line, decodable, with an ISO 8601 UTC timestamp" do
      encoded = Format.encode(event(), :json) |> IO.iodata_to_binary()

      assert String.ends_with?(encoded, "\n")
      assert [line] = String.split(encoded, "\n", trim: true)

      decoded = Jason.decode!(line)

      assert decoded["event"] == "secret_viewed"
      assert decoded["user"] == "alice"
      assert decoded["tenant"] == "acme"
      assert decoded["timestamp"] == "2026-08-11T12:34:56Z"
      assert decoded["source_ip"] == "203.0.113.7"
      assert decoded["resource"] == "acme/prod/api-key"
    end
  end

  describe "encode/2 with :text" do
    @tag :unit
    test "contains event, user, tenant, resource" do
      text = Format.encode(event(), :text) |> IO.iodata_to_binary()

      assert text =~ ~s(event="secret_viewed")
      assert text =~ ~s(user="alice")
      assert text =~ ~s(tenant="acme")
      assert text =~ ~s(resource="acme/prod/api-key")
    end

    @tag :unit
    test "a % or {} in the resource path does not corrupt the output" do
      tricky = event(%{resource: ~s(acme/prod/{weird}%20path)})

      text = Format.encode(tricky, :text) |> IO.iodata_to_binary()

      assert [line] = String.split(text, "\n", trim: true)
      assert line =~ ~s(resource="acme/prod/{weird}%20path")
    end
  end

  describe "the AUD-A05 guard" do
    @tag :unit
    test "the same event produces the same field set under both formats" do
      full =
        event(%{
          event: :auth_failure,
          reason: "token expired",
          details: %{path: "/api/secrets"}
        })

      json_fields =
        Format.encode(full, :json)
        |> IO.iodata_to_binary()
        |> Jason.decode!()
        |> Map.keys()
        |> MapSet.new()

      text = Format.encode(full, :text) |> IO.iodata_to_binary()

      text_keys =
        text
        |> String.trim()
        |> String.split(" ")
        |> Enum.map(fn pair -> pair |> String.split("=", parts: 2) |> List.first() end)
        |> MapSet.new()

      # JSON always carries "details" as a nested object; text flattens each
      # detail key to the top level instead of a container key — the field
      # *set* recorded is identical, only its shape differs, which is what
      # AUD-A05 requires.
      json_without_container = MapSet.delete(json_fields, "details")

      assert MapSet.subset?(json_without_container, text_keys)
      assert MapSet.subset?(MapSet.new(["path"]), text_keys)
    end

    @tag :unit
    test "holds for a record with nil optional fields, as a real secret_viewed emits" do
      # secret_viewed never carries reason, source_ip, or details — nil
      # top-level fields are exactly the case that must not vanish from one
      # format and not the other.
      sparse =
        event(%{
          source_ip: nil,
          reason: nil,
          details: %{}
        })

      json_keys =
        Format.encode(sparse, :json)
        |> IO.iodata_to_binary()
        |> Jason.decode!()
        |> Map.keys()
        |> MapSet.new()
        |> MapSet.delete("details")

      text_keys =
        Format.encode(sparse, :text)
        |> IO.iodata_to_binary()
        |> String.trim()
        |> String.split(" ")
        |> Enum.map(fn pair -> pair |> String.split("=", parts: 2) |> List.first() end)
        |> MapSet.new()

      assert json_keys == text_keys
    end
  end

  describe "cast/1" do
    @tag :unit
    test "maps the AUDIT_FORMAT values to real formats" do
      assert Format.cast("json") == {:ok, :json}
      assert Format.cast("text") == {:ok, :text}
    end

    @tag :unit
    test "returns :error for anything else" do
      assert Format.cast("bogus") == :error
      assert Format.cast("") == :error
    end
  end
end
