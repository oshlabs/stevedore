defmodule Stevedore.Auth do
  @moduledoc """
  Registry credentials and the bearer-token challenge/exchange flow.

  Registries advertise how to authenticate via a `401` response carrying a
  `WWW-Authenticate: Bearer realm=…,service=…,scope=…` header. `parse_challenge/1` reads that
  header; `token/3` exchanges it (plus optional credentials) for a bearer token at the realm's
  token endpoint. Credentials can be supplied directly or loaded from `~/.docker/config.json`.

  Spec: [Docker token authentication](https://distribution.github.io/distribution/spec/auth/token/)
  and the distribution-spec authentication section.
  """

  alias Stevedore.Auth.Error

  @type creds :: :anonymous | {:basic, user :: String.t(), pass :: String.t()}

  @type challenge :: %{realm: String.t(), service: String.t() | nil, scope: String.t() | nil}

  @doc """
  Parses a `WWW-Authenticate` header value. Only the `Bearer` scheme is supported; `Basic` and
  unknown schemes return `{:error, :unsupported}`.

  ## Examples

      iex> Stevedore.Auth.parse_challenge(~s(Bearer realm="https://auth.docker.io/token",service="registry.docker.io",scope="repository:library/alpine:pull"))
      {:ok, %{realm: "https://auth.docker.io/token", service: "registry.docker.io", scope: "repository:library/alpine:pull"}}

      iex> Stevedore.Auth.parse_challenge("Basic realm=\\"registry\\"")
      {:error, :unsupported}
  """
  @spec parse_challenge(String.t()) :: {:ok, challenge()} | {:error, :unsupported}
  def parse_challenge(header) when is_binary(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, params] ->
        if String.downcase(scheme) == "bearer" do
          parsed = parse_params(params)
          {:ok, %{realm: parsed["realm"], service: parsed["service"], scope: parsed["scope"]}}
        else
          {:error, :unsupported}
        end

      _ ->
        {:error, :unsupported}
    end
  end

  @doc """
  Exchanges a parsed `challenge` for a bearer token, sending `creds` as HTTP Basic to the token
  endpoint when they are not `:anonymous`.

  `opts` may carry `:req_options` (a keyword merged into the `Req` request, e.g. an `:adapter`)
  for testing.
  """
  @spec token(challenge(), creds(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def token(%{realm: realm} = challenge, creds \\ :anonymous, opts \\ []) when is_binary(realm) do
    params =
      [service: challenge[:service], scope: challenge[:scope]]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    req_opts =
      [url: realm, params: params]
      |> put_auth(creds)
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(req_opts) do
      {:ok, %{status: 200, body: body}} ->
        extract_token(body, realm)

      {:ok, %{status: status, body: body}} ->
        {:error, %Error{reason: :token_request_failed, status: status, body: body}}

      {:error, reason} ->
        {:error, %Error{reason: reason}}
    end
  end

  @doc """
  Loads credentials from a Docker config file (default `~/.docker/config.json`), returning a map
  of registry host to `t:creds/0`. A missing file yields an empty map.
  """
  @spec from_docker_config(Path.t() | nil) ::
          {:ok, %{optional(String.t()) => creds()}} | {:error, term()}
  def from_docker_config(path \\ nil) do
    path = path || Path.join([System.user_home!(), ".docker", "config.json"])

    case File.read(path) do
      {:ok, contents} -> parse_docker_config(contents)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Parse comma-separated `key="value"` parameters. The distribution-spec always quotes the
  # challenge parameters, so a quoted-value matcher covers real registries.
  @spec parse_params(String.t()) :: %{optional(String.t()) => String.t()}
  defp parse_params(params) do
    ~r/(\w+)="([^"]*)"/
    |> Regex.scan(params)
    |> Map.new(fn [_, key, value] -> {key, value} end)
  end

  @spec put_auth(keyword(), creds()) :: keyword()
  defp put_auth(req_opts, {:basic, user, pass}),
    do: Keyword.put(req_opts, :auth, {:basic, "#{user}:#{pass}"})

  defp put_auth(req_opts, :anonymous), do: req_opts

  @spec extract_token(term(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  defp extract_token(body, realm) when is_map(body) do
    case body["token"] || body["access_token"] do
      token when is_binary(token) -> {:ok, token}
      _ -> {:error, %Error{reason: :no_token_in_response, registry: realm, body: body}}
    end
  end

  defp extract_token(body, realm),
    do: {:error, %Error{reason: :unexpected_token_response, registry: realm, body: body}}

  @spec parse_docker_config(binary()) ::
          {:ok, %{optional(String.t()) => creds()}} | {:error, term()}
  defp parse_docker_config(contents) do
    case JSON.decode(contents) do
      {:ok, %{} = json} ->
        auths =
          (json["auths"] || %{})
          |> Enum.flat_map(fn {registry, entry} -> decode_auth(registry, entry) end)
          |> Map.new()

        {:ok, auths}

      _ ->
        {:error, {:bad_input, "docker config is not valid JSON"}}
    end
  end

  @spec decode_auth(String.t(), map()) :: [{String.t(), creds()}]
  defp decode_auth(registry, %{"auth" => b64}) when is_binary(b64) do
    with {:ok, decoded} <- Base.decode64(b64),
         [user, pass] <- String.split(decoded, ":", parts: 2) do
      [{registry, {:basic, user, pass}}]
    else
      _ -> []
    end
  end

  defp decode_auth(_registry, _entry), do: []
end
