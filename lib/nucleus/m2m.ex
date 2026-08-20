defmodule Nucleus.M2M do
  @moduledoc """
  The fail-closed resolution gate every M2M client action mounts through
  (`M2M-A13`, `M2M-A14`) — the same structure `Nucleus.Environments.fetch/2`
  gives `SEC-S1`, one boundary over.

  `NucleusWeb.M2MClientsLive` talks to this module, never to
  `Nucleus.M2M.Clients` directly, so the gate cannot be bypassed — the same
  rule `Nucleus.Secrets` states about `Nucleus.Secrets.Store`.

  ## Note the asymmetry with Secrets

  Secrets has a per-environment gate because the environment comes from the
  URL. M2M has no environment: the tenant is fixed per deployment
  (`TENANT_NAMESPACE`, one Nucleus instance per tenant, no runtime
  switching), so this gate is about the *client identifier* and the *client
  name*, not about a caller-supplied scope. `scope` is still accepted by
  `fetch/2`, matching every other context function's call-site shape, but no
  field of it is read here — tenancy comes from
  `Nucleus.M2M.ClientName.prefix/0` (deployment config), and this function
  emits no audit event (see below), so there is nothing here that needs the
  caller's identity or token.

  ## Strict ordering — the substance of both actions

  1. `Nucleus.M2M.ClientId.validate/1` — on error, returns
     `{:error, %Error{kind: :invalid}}` immediately. **No adapter call**
     (`M2M-A13`) — asserted structurally in `test/nucleus/m2m_test.exs` via a
     counting/raising module swapped in for the `:m2m` boundary, not merely
     inferred from behaviour. `Nucleus.Backend.Faults`' `LOCAL_FORCE_ERROR` is
     node-global (see `living-notes.md`) and cannot isolate this boundary's
     fault from any other, so that test does not use it.
  2. `Nucleus.M2M.DenyList.suffixes/0` — on `:not_configured`, returns it
     unchanged (fail closed, Decision 2). No adapter call on this branch
     either — an unreadable deny-list must not spend a request before
     failing.
  3. `Nucleus.M2M.Clients.describe_client/1` — any error
     (`:not_found`, `:auth_expired`, `:unavailable`, ...) passes through
     unchanged; this module manufactures none of its own error kinds here.
  4. `visible?/1` on the result — `false` collapses to `{:error, %Error{kind:
     :not_found}}`, **structurally identical** to the error
     `Nucleus.M2M.Clients.describe_client/1` itself returns for a genuinely
     nonexistent client (same message, same details shape). `M2M-A14`
     requires a deny-listed or out-of-tenant client be "never exposed here" —
     a distinct error kind or a distinguishing detail would itself confirm
     to the caller that the ID exists, which is exactly the information the
     requirement withholds.

  ## `visible?/1` is the one shared predicate

  Used by both this module's own step 4 and M2M-S2's list filter, so a
  future list-view fix cannot drift from this gate and leave a client
  invisible in the list but still rotatable by URL — the two-copies failure
  mode this predicate exists to prevent. `Nucleus.M2M.DenyList.denied?/1`
  also backs the creation-time guard (`M2M-A18`, #38) directly, since a
  not-yet-created client has no `Client.t()`/`ClientDetail.t()` for
  `visible?/1` to take.

  ## No audit event

  The wiki's audit table has three M2M events and none of them is a lookup
  or a rejection. `m2m_client_viewed` belongs to M2M-S3, on the detail view,
  not here — this function is also called by the rotation path, and
  emitting here would log a spurious "viewed" on every rotation.
  """

  alias Nucleus.Backend.Error
  alias Nucleus.M2M.Client
  alias Nucleus.M2M.ClientDetail
  alias Nucleus.M2M.ClientId
  alias Nucleus.M2M.ClientName
  alias Nucleus.M2M.Clients
  alias Nucleus.M2M.DenyList
  alias Nucleus.Scope

  @boundary :m2m

  @doc """
  Validates, resolves, and gates `client_id` to this tenant's client detail.

  Strict order — see the module doc. `scope` is accepted for call-site
  symmetry with every other context function but is not read by this
  function; see the module doc for why.
  """
  @spec fetch(client_id :: term(), scope :: Scope.t()) ::
          {:ok, ClientDetail.t()} | {:error, Error.t()}
  def fetch(client_id, %Scope{} = _scope) do
    with :ok <- ClientId.validate(client_id),
         {:ok, _suffixes} <- DenyList.suffixes(),
         {:ok, detail} <- Clients.describe_client(client_id) do
      if visible?(detail) do
        {:ok, detail}
      else
        not_found(client_id)
      end
    end
  end

  @doc """
  Whether `client` belongs to this tenant and is not on the reserved
  deny-list — the shared predicate behind this module's `fetch/2` (step 4)
  and M2M-S2's list filter.

  Accepts either a `Nucleus.M2M.Client.t()` (the list row) or a
  `Nucleus.M2M.ClientDetail.t()` (this module's own resolved struct) — both
  carry a `client_name`, the only field this check needs.
  """
  @spec visible?(Client.t() | ClientDetail.t()) :: boolean()
  def visible?(%{client_name: client_name}) when is_binary(client_name) do
    ClientName.in_tenant?(client_name) and not DenyList.denied?(client_name)
  end

  defp not_found(client_id) do
    {:error, Error.new(:not_found, @boundary, "no such client", %{client_id: client_id})}
  end
end
