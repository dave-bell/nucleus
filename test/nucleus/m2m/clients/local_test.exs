defmodule Nucleus.M2M.Clients.LocalTest do
  # Fault injection is read from the OS environment, which is global to the node.
  use ExUnit.Case, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Seed
  alias Nucleus.M2M.Client
  alias Nucleus.M2M.ClientCredentials
  alias Nucleus.M2M.ClientDetail
  alias Nucleus.M2M.Clients.Local

  @default_settings [token_validity_minutes: 15]

  setup do
    on_exit(&Seed.reset/0)
    :ok
  end

  defp force_error(kind) do
    System.put_env("LOCAL_FORCE_ERROR", kind)
    on_exit(fn -> System.delete_env("LOCAL_FORCE_ERROR") end)
  end

  describe "the seeded fixtures" do
    test "the deny-listed-suffix fixture is returned unfiltered — filtering is M2M-S1's job" do
      assert {:ok, clients} = Local.list_clients()
      assert Enum.any?(clients, &String.ends_with?(&1.client_name, "-internal"))
    end

    test "the out-of-tenant-prefix fixture is returned unfiltered" do
      assert {:ok, clients} = Local.list_clients()
      assert Enum.any?(clients, &String.starts_with?(&1.client_name, "other-tenant-"))
    end

    test "list_clients/0 returns clients with varied created_date values" do
      assert {:ok, clients} = Local.list_clients()
      dates = clients |> Enum.map(& &1.created_date) |> Enum.uniq()
      assert length(dates) > 1
    end

    test "a client with an exactly-one-hour validity (3600 seconds) is seeded" do
      assert {:ok, clients} = Local.list_clients()

      assert Enum.find_value(clients, fn %Client{client_id: id} ->
               case Local.describe_client(id) do
                 {:ok, %ClientDetail{token_validity_seconds: 3600}} -> id
                 _other -> nil
               end
             end)
    end

    test "a client with a non-round-minute validity (450 seconds) is seeded" do
      assert {:ok, clients} = Local.list_clients()

      assert Enum.find_value(clients, fn %Client{client_id: id} ->
               case Local.describe_client(id) do
                 {:ok, %ClientDetail{token_validity_seconds: 450}} -> id
                 _other -> nil
               end
             end)
    end

    test "no client in the list carries a :client_secret key" do
      assert {:ok, clients} = Local.list_clients()
      refute Enum.any?(clients, &Map.has_key?(&1, :client_secret))
    end
  end

  describe "describe_client/1" do
    test "an unknown client ID is :not_found" do
      assert {:error, %Error{kind: :not_found}} = Local.describe_client("no-such-client")
    end

    test "returns no :client_secret key" do
      assert {:ok, [%Client{client_id: id} | _]} = Local.list_clients()
      assert {:ok, detail} = Local.describe_client(id)
      refute Map.has_key?(detail, :client_secret)
    end
  end

  describe "create_client/2" do
    test "always creates, even with a name that already exists — no M2M-A09" do
      assert {:ok, first} = Local.create_client("dup-client", @default_settings)
      assert {:ok, second} = Local.create_client("dup-client", @default_settings)
      refute first.client_id == second.client_id
    end

    test "rejects a token_validity_minutes outside 5..60" do
      assert {:error, %Error{kind: :invalid}} =
               Local.create_client("bad-client", token_validity_minutes: 4)

      assert {:error, %Error{kind: :invalid}} =
               Local.create_client("bad-client", token_validity_minutes: 61)

      assert {:error, %Error{kind: :invalid}} =
               Local.create_client("bad-client", token_validity_minutes: "15")
    end

    test "accepts the boundary values 5 and 60" do
      assert {:ok, _} = Local.create_client("boundary-client-a", token_validity_minutes: 5)
      assert {:ok, _} = Local.create_client("boundary-client-b", token_validity_minutes: 60)
    end

    test "the returned credentials round-trip through describe_client/1" do
      assert {:ok, %ClientCredentials{client_id: client_id, client_name: "new-client"}} =
               Local.create_client("new-client", @default_settings)

      assert {:ok, %ClientDetail{client_name: "new-client", token_validity_seconds: 900}} =
               Local.describe_client(client_id)
    end
  end

  describe "rotate_secret/1" do
    test "returns a new secret for the same client_id" do
      assert {:ok, created} = Local.create_client("rotate-client", @default_settings)
      assert {:ok, rotated} = Local.rotate_secret(created.client_id)

      assert rotated.client_id == created.client_id
      refute rotated.client_secret == created.client_secret
    end

    test "on an unknown client ID is :not_found" do
      assert {:error, %Error{kind: :not_found}} = Local.rotate_secret("no-such-client")
    end

    test "genuinely retains exactly one previous secret, never two" do
      assert {:ok, created} = Local.create_client("two-secret-client", @default_settings)
      assert {:ok, rotated_once} = Local.rotate_secret(created.client_id)

      secrets_after_one_rotation = seeded_secrets(created.client_id)
      assert length(secrets_after_one_rotation) == 2

      values_after_one_rotation = Enum.map(secrets_after_one_rotation, & &1["value"])
      assert created.client_secret in values_after_one_rotation
      assert rotated_once.client_secret in values_after_one_rotation

      assert {:ok, rotated_twice} = Local.rotate_secret(created.client_id)

      secrets_after_two_rotations = seeded_secrets(created.client_id)
      assert length(secrets_after_two_rotations) == 2

      values_after_two_rotations = Enum.map(secrets_after_two_rotations, & &1["value"])
      refute created.client_secret in values_after_two_rotations
      assert rotated_once.client_secret in values_after_two_rotations
      assert rotated_twice.client_secret in values_after_two_rotations
    end

    defp seeded_secrets(client_id) do
      Seed.read(:m2m) |> get_in([client_id, "secrets"])
    end
  end

  describe "health_check/0" do
    test "is :ok" do
      assert Local.health_check() == :ok
    end
  end

  describe "state resets between tests" do
    test "part one: creates a client" do
      assert {:ok, _credentials} = Local.create_client("reset-probe", @default_settings)
      assert {:ok, [_ | _]} = Local.list_clients()
    end

    test "part two: the previous test's client is gone" do
      assert {:ok, clients} = Local.list_clients()
      refute Enum.any?(clients, &(&1.client_name == "reset-probe"))
    end
  end

  describe "fault injection" do
    @kinds Error.kinds()

    test "LOCAL_FORCE_ERROR=auth_expired surfaces on every one of the five callbacks" do
      force_error("auth_expired")

      assert {:error, %Error{kind: :auth_expired}} = Local.list_clients()
      assert {:error, %Error{kind: :auth_expired}} = Local.describe_client("any")
      assert {:error, %Error{kind: :auth_expired}} = Local.create_client("any", @default_settings)
      assert {:error, %Error{kind: :auth_expired}} = Local.rotate_secret("any")
      assert {:error, %Error{kind: :auth_expired}} = Local.health_check()
    end

    test "every declared Error kind is a valid LOCAL_FORCE_ERROR value" do
      for kind <- @kinds do
        force_error(Atom.to_string(kind))
        assert {:error, %Error{kind: ^kind}} = Local.health_check()
        System.delete_env("LOCAL_FORCE_ERROR")
      end
    end
  end

  describe "the empty-tenant path (M2M-A02's local equivalent)" do
    test "an empty section is {:ok, []}, not an error" do
      Seed.write(:m2m, %{})

      assert {:ok, []} = Local.list_clients()
    end
  end

  describe "a broken seed section" do
    test "reads as :not_configured when the section is absent" do
      Seed.write(:m2m, nil)

      assert {:error, %Error{kind: :not_configured}} = Local.list_clients()
    end

    test "reads as :not_configured when the section is not a map" do
      Seed.write(:m2m, "not a map")

      assert {:error, %Error{kind: :not_configured}} = Local.list_clients()
    end

    test "fails health_check/0" do
      Seed.write(:m2m, nil)

      assert {:error, %Error{kind: :not_configured}} = Local.health_check()
    end
  end
end
