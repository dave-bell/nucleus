defmodule Nucleus.M2M.ClientName do
  @moduledoc """
  The one place an M2M client name is built and recognised.

  `{tenant}-control-plane-{ticket_id}-{purpose}` — `Platform-Operations.md`
  confirms `TENANT_NAMESPACE` is "used for Nomad/M2M naming and audit
  records," so `Nucleus.Scope.tenant_namespace/0` is the right source here,
  not a new configuration surface.

  ## This module assumes pre-validated input

  `build/2` does not validate `ticket_id` or `purpose` — see
  `Nucleus.M2M.TicketId` and `Nucleus.M2M.Purpose` for that, enforced
  *before* this is called (the same note `Nucleus.Secrets.Path`'s moduledoc
  carries, so nothing mistakes this for a sanitiser). It concatenates its
  arguments verbatim.

  ## Every construction site goes through here

  Nothing outside this module builds an M2M client name by hand —
  `rg 'ClientName.build'` finding every call site is the point. The gate
  (`Nucleus.M2M.fetch/2`) and the eventual list filter (M2M-S2) both need the
  tenant prefix and must not construct it independently, so it is exposed as
  `prefix/0` rather than inlined wherever `in_tenant?/1` is checked.

  ## Tenancy is the full prefix, not `{tenant}-` — M2M-S1 Decision 8

  The Cognito user pool is shared across tenants today (one Nucleus instance
  per tenant, but one pool). The shorter `{tenant}-` prefix is not
  collision-safe in a shared pool: tenant `acme` would match
  `acme-corp-nomad`, reading and offering secret rotation on another
  tenant's client — the exact defect `M2M-A14` exists to prevent.
  `{tenant}-control-plane-` does not have this problem:
  `acme-corp-control-plane-X` does not start with `acme-control-plane-`. See
  [Decision 8](https://github.com/dave-bell/nucleus/issues/34#issuecomment-5350436093).
  """

  @doc """
  Builds the client name for `ticket_id`/`purpose`, tenant read at call time.

  Assumes both arguments are already validated (see the module doc).

      iex> Application.put_env(:nucleus, Nucleus.Scope, tenant_namespace: "acme")
      iex> Nucleus.M2M.ClientName.build("OPS-1234", "nightly-sync")
      "acme-control-plane-OPS-1234-nightly-sync"
  """
  @spec build(ticket_id :: String.t(), purpose :: String.t()) :: String.t()
  def build(ticket_id, purpose) when is_binary(ticket_id) and is_binary(purpose) do
    prefix() <> ticket_id <> "-" <> purpose
  end

  @doc """
  The tenant prefix every M2M client name built by this module carries,
  read at call time — `"{tenant}-control-plane-"`.

      iex> Application.put_env(:nucleus, Nucleus.Scope, tenant_namespace: "acme")
      iex> Nucleus.M2M.ClientName.prefix()
      "acme-control-plane-"
  """
  @spec prefix() :: String.t()
  def prefix, do: Nucleus.Scope.tenant_namespace() <> "-control-plane-"

  @doc """
  Whether `client_name` belongs to this tenant — a `String.starts_with?/2`
  check against `prefix/0`, not a substring check, so
  `"x-{tenant}-control-plane-..."` (the prefix appearing later in the
  string) is correctly `false`.

      iex> Application.put_env(:nucleus, Nucleus.Scope, tenant_namespace: "acme")
      iex> Nucleus.M2M.ClientName.in_tenant?("acme-control-plane-OPS-1-x")
      true

      iex> Application.put_env(:nucleus, Nucleus.Scope, tenant_namespace: "acme")
      iex> Nucleus.M2M.ClientName.in_tenant?("other-tenant-control-plane-OPS-1-x")
      false

      iex> Nucleus.M2M.ClientName.in_tenant?("")
      false
  """
  @spec in_tenant?(client_name :: String.t()) :: boolean()
  def in_tenant?(client_name) when is_binary(client_name) do
    String.starts_with?(client_name, prefix())
  end
end
