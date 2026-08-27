defmodule Nucleus.Backend.SeedTest do
  use ExUnit.Case, async: true

  alias Nucleus.Backend.Seed

  @fixture %{
    "tenant_api" => %{"environments" => [%{"shortName" => "fixture"}]},
    "secrets" => %{"prod" => %{"KEY" => "value"}}
  }

  defp seed_file(contents) do
    path = Path.join(System.tmp_dir!(), "seed-#{System.unique_integer([:positive])}.json")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp isolated_seed(contents \\ Jason.encode!(@fixture)) do
    start_supervised!(
      {Seed, name: :"seed_#{System.unique_integer([:positive])}", path: seed_file(contents)},
      id: System.unique_integer([:positive])
    )
  end

  describe "the checked-in seed" do
    test "is served by the process the application supervises" do
      assert %{"environments" => environments} = Seed.read(:tenant_api)
      assert is_list(environments)
    end

    test "returns nil for a boundary with no section, rather than raising" do
      # #4 has not landed, so there is no "secrets" section yet. A boundary whose
      # data arrives later must read as absent, not as broken.
      assert Seed.read(:no_such_boundary) == nil
    end
  end

  describe "sections" do
    test "each boundary reads only its own" do
      seed = isolated_seed()

      assert Seed.read(:tenant_api, seed) == @fixture["tenant_api"]
      assert Seed.read(:secrets, seed) == @fixture["secrets"]
    end

    test "writing one leaves the others untouched" do
      seed = isolated_seed()

      Seed.write(:tenant_api, %{"environments" => []}, seed)

      assert Seed.read(:tenant_api, seed) == %{"environments" => []}
      assert Seed.read(:secrets, seed) == @fixture["secrets"]
    end

    test "update/3 applies a function to the current section" do
      seed = isolated_seed()

      Seed.update(:secrets, &Map.put(&1, "staging", %{}), seed)

      assert Seed.read(:secrets, seed) == %{"prod" => %{"KEY" => "value"}, "staging" => %{}}
    end

    test "update/3 on an absent section is handed nil" do
      seed = isolated_seed()

      Seed.update(:brand_new, fn nil -> %{"created" => true} end, seed)

      assert Seed.read(:brand_new, seed) == %{"created" => true}
    end

    test "get_and_update/3 replaces the section and returns fun's own result" do
      seed = isolated_seed()

      result =
        Seed.get_and_update(
          :secrets,
          fn secrets -> {Map.keys(secrets), Map.put(secrets, "staging", %{})} end,
          seed
        )

      assert result == ["prod"]
      assert Seed.read(:secrets, seed) == %{"prod" => %{"KEY" => "value"}, "staging" => %{}}
    end

    test "get_and_update/3 can leave the section untouched while still returning a result" do
      seed = isolated_seed()

      result = Seed.get_and_update(:secrets, fn secrets -> {:unchanged, secrets} end, seed)

      assert result == :unchanged
      assert Seed.read(:secrets, seed) == @fixture["secrets"]
    end

    test "get_and_update/3 on an absent section is handed nil" do
      seed = isolated_seed()

      result =
        Seed.get_and_update(:brand_new, fn nil -> {:was_nil, %{"created" => true}} end, seed)

      assert result == :was_nil
      assert Seed.read(:brand_new, seed) == %{"created" => true}
    end

    test "get_and_update/3 serialises concurrent callers — no interleaved read-modify-write" do
      seed = isolated_seed(Jason.encode!(%{"counter" => %{"value" => 0}}))

      1..50
      |> Task.async_stream(
        fn _ ->
          Seed.get_and_update(
            :counter,
            fn %{"value" => value} -> {:ok, %{"value" => value + 1}} end,
            seed
          )
        end,
        max_concurrency: 10
      )
      |> Stream.run()

      assert Seed.read(:counter, seed) == %{"value" => 50}
    end
  end

  describe "reset/1" do
    test "discards runtime mutations, re-reading the file the instance was started with" do
      seed = isolated_seed()
      Seed.write(:tenant_api, %{"environments" => []}, seed)

      Seed.reset(seed)

      assert Seed.read(:tenant_api, seed) == @fixture["tenant_api"]
    end
  end

  describe "a malformed seed" do
    @describetag :capture_log

    test "raises rather than starting with a partial document" do
      path = seed_file(~s({"tenant_api": ))

      assert start_failure({Seed, name: :malformed_seed, path: path}) =~ "not valid JSON"
    end

    test "raises when the document is not an object" do
      path = seed_file(~s(["prod"]))

      assert start_failure({Seed, name: :non_object_seed, path: path}) =~ "must be a JSON object"
    end

    test "raises when the file is missing" do
      assert start_failure({Seed, name: :missing_seed, path: "/nonexistent/seed.json"}) =~
               "cannot read backend seed"
    end
  end

  # A crash in `init` surfaces as a nested `{{exception, stacktrace}, child_spec}`
  # reason. Dig the message out rather than asserting on that shape, which is an
  # OTP detail this suite has no interest in pinning.
  defp start_failure(child_spec) do
    assert {:error, reason} = start_supervised(child_spec)
    message(reason)
  end

  defp message({nested, _info}), do: message(nested)
  defp message(%_struct{} = exception), do: Exception.message(exception)
end
