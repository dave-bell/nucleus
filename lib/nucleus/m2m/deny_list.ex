defmodule Nucleus.M2M.DenyList do
  @moduledoc """
  The reserved-suffix deny-list `M2M-A01`, `M2M-A14`, and `M2M-A18` all share
  — clients whose name ends with a configured suffix are reserved for
  internal system use and are never listed, resolved, or creatable through
  this feature.

  Per [Decision 2](https://github.com/dave-bell/nucleus/issues/34#issuecomment-5350433802).

  ## `parse/1` is pure, `suffixes/0` reads config at call time

  `parse/1` turns a raw `M2M_DENY_SUFFIXES` string (or `nil`) into either
  `{:ok, [String.t()]}` or `:unset`, with no I/O. `suffixes/0` is the
  call-time read — `config/runtime.exs` calls `parse/1` once at boot and
  only sets the app-env key on `{:ok, _}`, so an absent key is this module's
  own `:not_configured` signal, matching `Nucleus.Secrets.Path`'s and
  ADR-0009's fail-closed precedent. Reading at call time, not compile time,
  means both `config/runtime.exs` and a test's `Application.put_env/3`
  override take effect — the same pattern `Nucleus.Backend.impl_for/1` uses.

  ## Unset or blank fails closed; `none` is the explicit opt-out

  `nil`, `""`, whitespace-only, or a value that splits to nothing (`","`,
  `",,"`) all parse to `:unset` — `suffixes/0` then returns
  `{:error, %Error{kind: :not_configured}}` rather than silently treating an
  unset deny-list as an empty one. `M2M_DENY_SUFFIXES=""` is far more likely
  to be a Terraform template rendering nothing than a deliberate choice, and
  a silently empty deny-list is exactly the widening failure this module
  exists to prevent. The literal value `"none"` (case-insensitive) is the
  one way to say "deny nothing" on purpose.

  ## No regex built from configuration

  `denied?/1` downcases both the configured suffix and the client name, then
  checks with `String.ends_with?/2` — literal suffix matching, never a
  regex compiled from an operator-supplied string. An operator-supplied
  suffix containing regex metacharacters (`"-a.b"`) would either crash a
  regex-based check or match far more than intended; a literal check treats
  every character literally by construction.

  ## Under Decision 8, this is a reserved-*purpose* list, not a general
  reserved-name list

  With `Nucleus.M2M.ClientName`'s full `{tenant}-control-plane-` prefix
  (Decision 8), this list can only ever catch a reserved name that *also*
  follows the control-plane naming convention — it no longer needs to guard
  against arbitrary platform-internal client names, since the prefix check
  already excludes those. Five of the six configured suffixes
  (`-nucleus`, `-orange`, `-faas-api`, `-faas-ui`, `-labops-ui`) are reachable
  as an M2M `purpose` and matter for the creation guard (`M2M-A18`,
  Decision 9); `-device_grant` contains an underscore, which
  `Nucleus.M2M.Purpose`'s `[a-z0-9-]+` charset can never produce — it can
  only ever match a name Nucleus did not build, so it matters only for the
  list/detail gate, never for creation.
  """

  alias Nucleus.Backend.Error

  @boundary :m2m
  @none_sentinel "none"

  @doc """
  Parses a raw `M2M_DENY_SUFFIXES` value.

  Pure — no I/O, no config read. `nil`, `""`, whitespace-only, or a value
  that splits to nothing all return `:unset`. The literal value `"none"`
  (case-insensitive) returns `{:ok, []}` — an explicit, deliberate empty
  deny-list. Otherwise: split on `,`, trim each entry, drop empties,
  downcase, and return `{:ok, [String.t()]}`.

      iex> Nucleus.M2M.DenyList.parse(nil)
      :unset

      iex> Nucleus.M2M.DenyList.parse("")
      :unset

      iex> Nucleus.M2M.DenyList.parse(",,")
      :unset

      iex> Nucleus.M2M.DenyList.parse("none")
      {:ok, []}

      iex> Nucleus.M2M.DenyList.parse("NONE")
      {:ok, []}

      iex> Nucleus.M2M.DenyList.parse("-orange,-nucleus")
      {:ok, ["-orange", "-nucleus"]}

      iex> Nucleus.M2M.DenyList.parse(" -orange , -NUCLEUS ")
      {:ok, ["-orange", "-nucleus"]}
  """
  @spec parse(String.t() | nil) :: {:ok, [String.t()]} | :unset
  def parse(nil), do: :unset

  def parse(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        :unset

      String.downcase(trimmed) == @none_sentinel ->
        {:ok, []}

      true ->
        suffixes =
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&String.downcase/1)

        if suffixes == [], do: :unset, else: {:ok, suffixes}
    end
  end

  @doc """
  The configured deny-list, read from `Application.get_env/3` at call time.

  `{:error, %Nucleus.Backend.Error{kind: :not_configured}}` when
  `config/runtime.exs` never called `parse/1` successfully — i.e. when
  `M2M_DENY_SUFFIXES` is unset or blank in this environment. Never falls
  back to an empty list on its own; that fallback would silently widen
  `M2M-A01`/`M2M-A14` from "reserved clients are hidden" to "reserved
  clients are shown," exactly the failure Decision 2 exists to prevent.
  """
  @spec suffixes() :: {:ok, [String.t()]} | {:error, Error.t()}
  def suffixes do
    case Application.get_env(:nucleus, __MODULE__, []) |> Keyword.get(:suffixes) do
      list when is_list(list) ->
        {:ok, list}

      _absent ->
        {:error,
         Error.new(:not_configured, @boundary, "M2M_DENY_SUFFIXES is not configured", %{})}
    end
  end

  @doc """
  Whether `client_name` ends with a configured reserved suffix.

  Case-insensitive: downcases both the configured suffix and `client_name`
  before `String.ends_with?/2`, so a Terraform- or console-created name that
  is not lowercase by construction (unlike every Nucleus-built name) is
  still caught — the fail-safe direction for a deny-list is to match more,
  not less.

  Fails closed on unconfigured suffixes too: if `suffixes/0` itself returns
  `:not_configured`, this returns `true` rather than silently treating an
  unreadable deny-list as an empty one. In practice `Nucleus.M2M.fetch/2`
  never reaches this branch — it checks `suffixes/0` directly, first, and
  returns `:not_configured` before ever calling this — but `denied?/1` is
  also exposed standalone for the creation-time guard (`M2M-A18`, #38),
  which has no equivalent earlier check of its own.

      iex> Application.put_env(:nucleus, Nucleus.M2M.DenyList, suffixes: ["-nucleus", "-orange"])
      iex> Nucleus.M2M.DenyList.denied?("local-control-plane-OPS-1042-nucleus")
      true

      iex> Application.put_env(:nucleus, Nucleus.M2M.DenyList, suffixes: ["-nucleus", "-orange"])
      iex> Nucleus.M2M.DenyList.denied?("local-control-plane-OPS-1042-NUCLEUS")
      true

      iex> Application.put_env(:nucleus, Nucleus.M2M.DenyList, suffixes: ["-nucleus"])
      iex> Nucleus.M2M.DenyList.denied?("local-control-plane-OPS-1042-billing")
      false

      iex> Application.put_env(:nucleus, Nucleus.M2M.DenyList, suffixes: [])
      iex> Nucleus.M2M.DenyList.denied?("local-control-plane-OPS-1042-nucleus")
      false
  """
  @spec denied?(client_name :: String.t()) :: boolean()
  def denied?(client_name) when is_binary(client_name) do
    case suffixes() do
      {:ok, suffixes} ->
        downcased_name = String.downcase(client_name)
        Enum.any?(suffixes, &String.ends_with?(downcased_name, &1))

      {:error, _not_configured} ->
        true
    end
  end
end
