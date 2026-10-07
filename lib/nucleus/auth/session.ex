defmodule Nucleus.Auth.Session do
  @moduledoc """
  What the signed-in browser's session cookie carries (`AUTH-A02`).

  Exactly the identity and two timestamps - no token of any kind. The cookie
  is encrypted (`NucleusWeb.Endpoint`), but "no secret in the session" is kept
  as a rule in its own right, because the cookie is also handed to every
  LiveView mount and would be one careless `inspect/1` from a template.

  Timestamps are Unix seconds:

  - `signed_in_at` - when the callback wrote this session. `SESSION_MAX_AGE`
    is measured from it, and it is the one clock a restart cannot lose.
  - `last_active` - advanced on every HTTP request. The authoritative idle
    clock is `Nucleus.Auth.SessionRegistry`'s, which LiveView activity also
    feeds (a LiveView cannot write a cookie); this copy is only the fallback
    for a session the registry has forgotten, i.e. after a restart.
  """

  @enforce_keys [:id, :signed_in_at, :last_active]
  defstruct [:id, :email, :username, :signed_in_at, :last_active]

  @type t :: %__MODULE__{
          id: String.t(),
          email: String.t() | nil,
          username: String.t() | nil,
          signed_in_at: integer(),
          last_active: integer()
        }

  @doc "A new session for the user in a verified ID token's `user`, signed in now."
  @spec new(%{email: String.t() | nil, username: String.t() | nil}, integer()) :: t()
  def new(%{email: email, username: username}, now) do
    %__MODULE__{
      id: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false),
      email: email,
      username: username,
      signed_in_at: now,
      last_active: now
    }
  end

  @spec touch(t(), integer()) :: t()
  def touch(%__MODULE__{} = session, now), do: %{session | last_active: now}

  @doc """
  The key Phoenix reads from the session to know which socket id to
  subscribe a LiveView to, so `Endpoint.broadcast(id, "disconnect", %{})`
  closes every tab of this session.
  """
  @spec live_socket_id(t() | String.t()) :: String.t()
  def live_socket_id(%__MODULE__{id: id}), do: live_socket_id(id)
  def live_socket_id(id) when is_binary(id), do: "auth_sessions:" <> id

  @doc "The identity to put on an audit event: email, else username, else `\"anonymous\"`."
  @spec audit_user(t()) :: String.t()
  def audit_user(%__MODULE__{email: email}) when is_binary(email) and email != "", do: email

  def audit_user(%__MODULE__{username: username}) when is_binary(username) and username != "",
    do: username

  def audit_user(%__MODULE__{}), do: "anonymous"
end
