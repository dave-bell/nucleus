defmodule Nucleus.Aws.Credentials do
  @moduledoc """
  `sts:AssumeRole` + `GetCallerIdentity`, cached, for any boundary that needs
  to reach an AWS account through a configured role ARN.

  Reads **no application env**. Everything it needs arrives in a `spec` the
  calling adapter assembles from its own config — see `t:spec/0`. `boundary`
  exists so the returned `Nucleus.Backend.Error` carries the right
  `boundary` field, and so the request-ID log lines correlate to the caller
  that made them rather than claiming to be `:secrets` regardless of who
  asked.

  ## Nucleus's own AWS identity

  Assuming `spec.role_arn` requires *some* AWS identity to call
  `sts:AssumeRole` as. That identity is Nucleus's own deployment
  configuration — shared across every boundary, not part of any adapter's
  config, and not a new config surface this ticket invents. It is read from
  the same environment variables any AWS SDK reads (`AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`), however the deployment
  platform makes them available. A missing pair is
  `{:error, %Error{kind: :not_configured}}`, never a crash.

  ## Credential handling

  `AWS.STS.assume_role/2` into `spec.role_arn` (`spec.external_id` if set),
  then `AWS.STS.get_caller_identity/2` on the *assumed* client to learn the
  account ID. Both are cached together in `Nucleus.Aws.CredentialCache`,
  keyed on `{role_arn, external_id, session_name}`, until
  `expiration - skew` (five minutes).

  On a credential-expiry-shaped failure the cache slot for that key is
  invalidated and the call returns `{:error, %Error{kind: :auth_expired}}`.
  Invalidating is what makes `SEC-A18`'s "a fresh attempt after
  re-authentication succeeds normally" true — retrying with the same
  rejected credentials would not.
  """

  require Logger

  alias Nucleus.Aws.Client
  alias Nucleus.Aws.CredentialCache
  alias Nucleus.Aws.Error
  alias Nucleus.Backend.Error, as: BackendError

  @skew_seconds 300

  @type spec :: %{
          boundary: atom(),
          role_arn: String.t(),
          region: String.t(),
          external_id: String.t() | nil,
          session_name: String.t(),
          http_client_opts: keyword()
        }

  @doc """
  Returns a ready-to-use `%AWS.Client{}` and the AWS account ID it belongs
  to, assuming `spec.role_arn` (and re-assuming it, past cache expiry).
  """
  @spec fetch(spec()) ::
          {:ok, %{client: AWS.Client.t(), account_id: String.t()}} | {:error, BackendError.t()}
  def fetch(spec) do
    with {:ok, cached} <- credentials(spec) do
      client =
        Client.build_client(
          cached.access_key_id,
          cached.secret_access_key,
          cached.session_token,
          spec.region,
          spec.http_client_opts
        )

      {:ok, %{client: client, account_id: cached.account_id}}
    end
  end

  @doc """
  The `Nucleus.Aws.CredentialCache` key for `spec` — `{role_arn, external_id,
  session_name}`. Exposed so a caller can build the same `ctx.cache_key` it
  hands to `Nucleus.Aws.Error.classify/3` without duplicating the tuple
  shape.
  """
  @spec cache_key(spec()) :: CredentialCache.key()
  def cache_key(spec), do: {spec.role_arn, spec.external_id, spec.session_name}

  defp credentials(spec) do
    case CredentialCache.get(cache_key(spec)) do
      %{expires_at: expires_at} = cached ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          {:ok, cached}
        else
          refresh_credentials(spec)
        end

      nil ->
        refresh_credentials(spec)
    end
  end

  defp refresh_credentials(spec) do
    with {:ok, base_client} <- base_client(spec),
         {:ok, assumed} <- do_assume_role(base_client, spec),
         {:ok, assume_result} <-
           unwrap_result(assumed, "AssumeRoleResponse", "AssumeRoleResult", spec) do
      creds = assume_result["Credentials"]

      assumed_client =
        Client.build_client(
          creds["AccessKeyId"],
          creds["SecretAccessKey"],
          creds["SessionToken"],
          spec.region,
          spec.http_client_opts
        )

      with {:ok, identity} <- do_get_caller_identity(assumed_client, spec),
           {:ok, identity_result} <-
             unwrap_result(identity, "GetCallerIdentityResponse", "GetCallerIdentityResult", spec) do
        cached = %{
          access_key_id: creds["AccessKeyId"],
          secret_access_key: creds["SecretAccessKey"],
          session_token: creds["SessionToken"],
          account_id: identity_result["Account"],
          expires_at: expires_at(creds["Expiration"])
        }

        CredentialCache.put(cache_key(spec), cached)
        {:ok, cached}
      end
    end
  end

  # STS is a query/XML-protocol service and this library's generic XML
  # decoder does not unwrap the operation envelope the way the JSON-protocol
  # SSM responses are already flat — `AWS.STS.assume_role/3`'s response
  # actually decodes to `%{"AssumeRoleResponse" => %{"AssumeRoleResult" =>
  # %{"Credentials" => ...}}}`, not `%{"Credentials" => ...}` at the top
  # level, whatever the generated module's documentation-only typespec claims.
  # Verified directly against `AWS.XML.decode!/2`, not assumed from docs.
  defp unwrap_result(body, response_key, result_key, spec) do
    case get_in(body, [response_key, result_key]) do
      %{} = result ->
        {:ok, result}

      _other ->
        {:error,
         BackendError.new(
           :unavailable,
           spec.boundary,
           "AWS returned an unexpected #{response_key} shape",
           %{}
         )}
    end
  end

  defp do_assume_role(client, spec) do
    request_id = request_id()
    Logger.info("#{spec.boundary} aws assume_role request_id=#{request_id}")

    input =
      %{"RoleArn" => spec.role_arn, "RoleSessionName" => spec.session_name}
      |> maybe_put("ExternalId", spec.external_id)

    client
    |> AWS.STS.assume_role(input)
    |> then(&Error.unwrap(client, &1))
    |> Error.as_backend_result(sts_ctx(spec), request_id)
  end

  defp do_get_caller_identity(client, spec) do
    request_id = request_id()
    Logger.info("#{spec.boundary} aws get_caller_identity request_id=#{request_id}")

    client
    |> AWS.STS.get_caller_identity(%{})
    |> then(&Error.unwrap(client, &1))
    |> Error.as_backend_result(sts_ctx(spec), request_id)
  end

  defp sts_ctx(spec) do
    %{
      boundary: spec.boundary,
      cache_key: cache_key(spec),
      codes: %{},
      transport_message: "AWS STS is unreachable"
    }
  end

  defp base_client(spec) do
    case {System.get_env("AWS_ACCESS_KEY_ID"), System.get_env("AWS_SECRET_ACCESS_KEY")} do
      {access_key_id, secret_access_key}
      when is_binary(access_key_id) and access_key_id != "" and is_binary(secret_access_key) and
             secret_access_key != "" ->
        {:ok,
         Client.build_client(
           access_key_id,
           secret_access_key,
           System.get_env("AWS_SESSION_TOKEN"),
           spec.region,
           spec.http_client_opts
         )}

      _missing ->
        {:error,
         BackendError.new(
           :not_configured,
           spec.boundary,
           "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must both be set",
           %{}
         )}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp request_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # STS is a query/XML-protocol service: the generic XML decoder (AWS.XML,
  # via xmerl) returns text nodes verbatim, so `Credentials.Expiration`
  # arrives as the ISO8601 string AWS actually puts in the XML
  # ("2026-08-01T12:00:00Z"), not an epoch integer — unlike SSM's JSON
  # responses, which encode timestamps as numbers. Do not reuse an
  # epoch-based parser here.
  defp parse_sts_timestamp(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_sts_timestamp(_other), do: nil

  # A missing or unparseable `Expiration` is treated as already-expired rather
  # than crashing — the next call simply re-`assume_role`s.
  defp expires_at(iso8601) do
    case parse_sts_timestamp(iso8601) do
      nil -> DateTime.utc_now()
      datetime -> DateTime.add(datetime, -@skew_seconds, :second)
    end
  end
end
