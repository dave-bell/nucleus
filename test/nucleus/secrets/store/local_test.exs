defmodule Nucleus.Secrets.Store.LocalTest do
  # Fault injection is read from the OS environment, which is global to the node.
  use ExUnit.Case, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Seed
  alias Nucleus.Secrets.Secret
  alias Nucleus.Secrets.SecretRef
  alias Nucleus.Secrets.Store.Local

  setup do
    on_exit(&Seed.reset/0)
    :ok
  end

  defp force_error(kind) do
    System.put_env("LOCAL_FORCE_ERROR", kind)
    on_exit(fn -> System.delete_env("LOCAL_FORCE_ERROR") end)
  end

  describe "the seeded fixtures" do
    test "sandbox has zero secrets — the SEC-A14 empty-state fixture" do
      assert {:ok, []} = Local.list_secrets("sandbox")
    end

    test "shared has at least one entry" do
      assert {:ok, [_ | _] = refs} = Local.list_secrets("shared")
      assert Enum.all?(refs, &match?(%SecretRef{}, &1))
    end

    test "a 4096-character value round-trips intact — the SEC-A11 boundary fixture" do
      assert {:ok, [_ | _] = refs} = Local.list_secrets("prod")

      long_value =
        Enum.find_value(refs, fn %SecretRef{key: key} ->
          {:ok, %Secret{value: value}} = Local.get_secret("prod", key)
          if String.length(value) == 4096, do: value
        end)

      assert is_binary(long_value)
      assert String.length(long_value) == 4096
    end

    test "list_environments/0 includes prod, sandbox and shared" do
      assert {:ok, environments} = Local.list_environments()
      assert "prod" in environments
      assert "sandbox" in environments
      assert "shared" in environments
    end
  end

  describe "create_secret/3" do
    test "does not overwrite an existing key" do
      assert {:ok, _ref} = Local.create_secret("prod", "NEW_KEY", "v1")

      assert {:error, %Error{kind: :already_exists, boundary: :secrets}} =
               Local.create_secret("prod", "NEW_KEY", "v2")

      assert {:ok, %Secret{value: "v1"}} = Local.get_secret("prod", "NEW_KEY")
    end

    test "synthesises a path and ARN via Nucleus.Secrets.Path.build/2" do
      assert {:ok, %SecretRef{path: path, arn: arn}} =
               Local.create_secret("prod", "ARN_KEY", "v1")

      assert path =~ "prod/ARN_KEY"
      assert arn =~ "arn:aws:ssm:"
      assert String.ends_with?(arn, path)
    end
  end

  describe "update_secret/3" do
    test "never creates — a missing key is :not_found" do
      assert {:error, %Error{kind: :not_found, boundary: :secrets}} =
               Local.update_secret("prod", "DOES_NOT_EXIST", "v1")

      assert {:error, %Error{kind: :not_found}} = Local.get_secret("prod", "DOES_NOT_EXIST")
    end
  end

  describe "state resets between tests" do
    test "part one: creates a key" do
      assert {:ok, _ref} = Local.create_secret("prod", "RESET_PROBE", "v1")
      assert {:ok, _secret} = Local.get_secret("prod", "RESET_PROBE")
    end

    test "part two: the previous test's key is gone" do
      assert {:error, %Error{kind: :not_found}} = Local.get_secret("prod", "RESET_PROBE")
    end
  end

  describe "fault injection" do
    @kinds Error.kinds()

    test "LOCAL_FORCE_ERROR=auth_expired surfaces on every one of the eight callbacks" do
      force_error("auth_expired")

      assert {:error, %Error{kind: :auth_expired}} = Local.list_secrets("prod")
      assert {:error, %Error{kind: :auth_expired}} = Local.get_secret("prod", "any")
      assert {:error, %Error{kind: :auth_expired}} = Local.create_secret("prod", "any", "v")
      assert {:error, %Error{kind: :auth_expired}} = Local.update_secret("prod", "any", "v")
      assert {:error, %Error{kind: :auth_expired}} = Local.locate_secret("prod", "any")
      assert {:error, %Error{kind: :auth_expired}} = Local.list_environments()
      assert {:error, %Error{kind: :auth_expired}} = Local.list_all_secrets()
      assert {:error, %Error{kind: :auth_expired}} = Local.health_check()
    end

    test "every declared Error kind is a valid LOCAL_FORCE_ERROR value" do
      for kind <- @kinds do
        force_error(Atom.to_string(kind))
        assert {:error, %Error{kind: ^kind}} = Local.health_check()
        System.delete_env("LOCAL_FORCE_ERROR")
      end
    end

    test "an unparseable value raises rather than passing silently" do
      force_error("teapot")

      assert_raise ArgumentError, fn -> Local.list_secrets("prod") end
    end
  end

  describe "a broken seed section" do
    test "reads as :not_configured when the section is absent" do
      Seed.write(:secrets, nil)

      assert {:error, %Error{kind: :not_configured}} = Local.list_secrets("prod")
    end

    test "reads as :not_configured when the section is not a map" do
      Seed.write(:secrets, "not a map")

      assert {:error, %Error{kind: :not_configured}} = Local.list_secrets("prod")
    end

    test "fails health_check/0" do
      Seed.write(:secrets, nil)

      assert {:error, %Error{kind: :not_configured}} = Local.health_check()
    end
  end
end
