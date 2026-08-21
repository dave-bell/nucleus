defmodule Nucleus.M2M do
  @moduledoc """
  The fail-closed resolution gate every M2M client action mounts through
  (`M2M-A13`, `M2M-A14`) — the same structure `Nucleus.Environments.fetch/2`
  gives `SEC-S1`, one boundary over.

  `NucleusWeb.M2MClientsLive.Index` and `.Show` talk to this module, never to
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

  ## `fetch/2` and `list/1` emit no audit event; `view/2` does

  `fetch/2` is also called by the rotation path (M2M-S6), so emitting
  `m2m_client_viewed` there would log a spurious "viewed" on every rotation
  nobody performed as a view. `m2m_client_viewed` instead lives on `view/2`,
  the resolve-plus-audit wrapper `NucleusWeb.M2MClientsLive.Show` calls —
  see `view/2`'s own doc. `list/1` emits nothing either: the wiki's audit
  table has three M2M events and listing is not one of them.
  """

  alias Nucleus.Audit
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
  `fetch/2` plus the `m2m_client_viewed` audit emission (`M2M-A03`) — a
  distinct function, deliberately not folded into `fetch/2` itself.

  M2M-S6's rotation path also resolves the client through `fetch/2`;
  emitting the audit event there would record a spurious "viewed" on every
  rotation nobody performed as a view. Keeping `fetch/2` audit-free is
  M2M-S1 / #34's own guarantee, re-asserted by that ticket's test — this
  function must not weaken it.

  Emits **once per call, on success only**. A failed lookup — `:invalid`,
  `:not_found`, `:unavailable`, or any other kind `fetch/2` passes through —
  is not a view that happened and produces no audit record. Callers control
  "once per open, not per render" themselves: `NucleusWeb.M2MClientsLive.Show`
  calls this from `mount/3`, guarded by `connected?(socket)`, so one human
  open of the page produces exactly one call, not one per disconnected and
  connected render.

  `details` carries exactly `client_name` — the only key
  `Nucleus.Audit.Event`'s catalogue allowlists for this event
  (`lib/nucleus/audit/event.ex:110-115`); passing anything else is rejected
  by `Audit.emit/2` by design, not an obstacle to work around. `user` comes
  from `Nucleus.Scope.audit_user/1`, not a raw `scope.user.email` read —
  matching `Nucleus.Secrets.reveal/3` and ADR-0011's reasoning: a Cognito
  access token can carry no `email` claim, and `audit_user/1` already falls
  back to `username`, then `"anonymous"`, so a signed-in view is never
  misattributed just because `email` happened to be `nil` or blank.
  """
  @spec view(client_id :: term(), scope :: Scope.t()) ::
          {:ok, ClientDetail.t()} | {:error, Error.t()}
  def view(client_id, %Scope{} = scope) do
    case fetch(client_id, scope) do
      {:ok, detail} = ok ->
        :ok =
          Audit.emit(:m2m_client_viewed,
            user: Scope.audit_user(scope),
            tenant: scope.tenant,
            details: %{client_name: detail.client_name}
          )

        ok

      error ->
        error
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

  @doc """
  Every M2M client visible to this tenant — `M2M-A01`, `M2M-A02` (`M2M-S2`).

  Same strict order as `fetch/2`, minus the per-ID steps that don't apply to
  a list: deny-list config first (fail closed, no adapter call on
  `:not_configured`), then the adapter call, then the shared `visible?/1`
  filter — the same predicate `fetch/2` gates a single client through, so a
  client hidden here cannot remain resolvable by URL (see the module doc).

  A `Client` with `created_date_error` set (its per-row describe failed
  while listing) is filtered and sorted like any other — it is
  `Nucleus.M2M.Clients.list_clients/0`'s job to degrade that one row, not
  this function's job to drop it.

  Sorted case-insensitively by `client_name`, with the raw name as a
  tiebreak so the order is total: `ListUserPoolClients` paginates with no
  cross-page ordering guarantee, and the local implementation reads a
  JSON-decoded map whose iteration order is not insertion order past 32
  keys. Sorting here, not in the template, keeps the LiveView and its tests
  free of that concern. Same construction as `Nucleus.Secrets.list/2`.

  `scope` is accepted for call-site symmetry, unread — see the module doc's
  "Note the asymmetry with Secrets".

  **Emits no audit event.** The wiki's audit table has exactly three M2M
  events and listing is not among them — unlike Data Export's
  `nomad_vars_listed`, listing here exposes no secrets, so there is nothing
  sensitive to attribute.
  """
  @spec list(scope :: Scope.t()) :: {:ok, [Client.t()]} | {:error, Error.t()}
  def list(%Scope{} = _scope) do
    with {:ok, _suffixes} <- DenyList.suffixes(),
         {:ok, clients} <- Clients.list_clients() do
      visible =
        clients
        |> Enum.filter(&visible?/1)
        |> Enum.sort_by(&{String.downcase(&1.client_name), &1.client_name})

      {:ok, visible}
    end
  end

  defp not_found(client_id) do
    {:error, Error.new(:not_found, @boundary, "no such client", %{client_id: client_id})}
  end
end
