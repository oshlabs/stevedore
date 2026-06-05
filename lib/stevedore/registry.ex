defmodule Stevedore.Registry do
  @moduledoc """
  A daemonless client for the OCI/Docker Distribution v2 API (the `docker://` transport).

  Fetches manifests and blobs from a registry over HTTPS: it performs the anonymous
  bearer-token handshake (a `401` challenge exchanged at the token endpoint), negotiates manifest
  media types via `Accept`, honors `Docker-Content-Digest`, and verifies every blob against its
  digest. Manifest bytes are returned **raw** so their digest stays stable.

  This module requires the optional `:req` dependency; calling it without `req` raises a clear
  error. The functions return the shapes a runtime (e.g. Tank) consumes directly.

  Spec: [OCI distribution-spec, pull](https://github.com/opencontainers/distribution-spec/blob/main/spec.md#pull).
  """

  alias Stevedore.{Auth, Digest, MediaType, Reference}
  alias Stevedore.Registry.Error

  @doc """
  Fetches a manifest (or index) for `ref`, by its tag or digest.

  Returns the raw bytes, decoded JSON, resolved media type, and digest. When the registry sends
  `Docker-Content-Digest`, the bytes are verified against it.

  Options: `:creds` (`t:Stevedore.Auth.creds/0`, default `:anonymous`), `:scheme` (default
  `"https"`), `:max_retries`, and `:req_options` (a keyword merged into the `Req` request, e.g.
  an `:adapter` for tests).
  """
  @spec manifest(Reference.t(), keyword()) ::
          {:ok, %{media_type: String.t(), digest: Digest.t(), raw: binary(), json: map()}}
          | {:error, Error.t()}
  def manifest(%Reference{} = ref, opts \\ []) do
    ensure_req!()
    url = url(ref, "manifests", reference_part(ref), opts)
    headers = [{"accept", Enum.join(MediaType.all_manifest_types(), ", ")}]

    with {:ok, resp} <- authed_get(ref, url, headers, opts),
         {:ok, json} <- decode_manifest(resp.body, ref),
         {:ok, digest} <- resolve_digest(resp, resp.body, ref) do
      media_type = header(resp, "content-type") || json["mediaType"] || MediaType.oci_manifest()
      {:ok, %{media_type: media_type, digest: digest, raw: resp.body, json: json}}
    end
  end

  @doc """
  Fetches a blob (config or layer) for `ref` by `digest`, verifying the bytes against it.

  Survives CDN redirects without leaking the registry token: `req` strips the `Authorization`
  header on any cross-host redirect.
  """
  @spec blob(Reference.t(), Digest.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def blob(%Reference{} = ref, %Digest{} = digest, opts \\ []) do
    ensure_req!()
    url = url(ref, "blobs", Digest.to_string(digest), opts)

    with {:ok, resp} <- authed_get(ref, url, [], opts) do
      case Digest.verify(resp.body, digest) do
        :ok -> {:ok, resp.body}
        {:error, :digest_mismatch} -> {:error, error(ref, reason: :digest_mismatch)}
      end
    end
  end

  @doc """
  Lists all tags for `ref`'s repository, following `Link` pagination.
  """
  @spec list_tags(Reference.t(), keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list_tags(%Reference{} = ref, opts \\ []) do
    ensure_req!()
    list_tags_page(ref, url(ref, "tags/list", nil, opts), [], opts)
  end

  @spec list_tags_page(Reference.t(), String.t(), [String.t()], keyword()) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  defp list_tags_page(ref, url, acc, opts) do
    with {:ok, resp} <- authed_get(ref, url, [{"accept", "application/json"}], opts),
         {:ok, json} <- decode_json(resp.body, ref) do
      acc = acc ++ (json["tags"] || [])

      case next_link(resp, ref, opts) do
        nil -> {:ok, acc}
        next_url -> list_tags_page(ref, next_url, acc, opts)
      end
    end
  end

  # Perform a GET, handling a 401 bearer/basic challenge with a single authenticated retry.
  @spec authed_get(Reference.t(), String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, Req.Response.t()} | {:error, Error.t()}
  defp authed_get(ref, url, headers, opts) do
    case request(url, headers, opts, []) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, resp}

      {:ok, %{status: 401} = resp} ->
        retry_with_auth(ref, url, headers, opts, resp)

      {:ok, resp} ->
        {:error, error(ref, status: resp.status, reason: :request_failed, body: resp.body)}

      {:error, reason} ->
        {:error, error(ref, reason: reason)}
    end
  end

  @spec retry_with_auth(
          Reference.t(),
          String.t(),
          [{String.t(), String.t()}],
          keyword(),
          Req.Response.t()
        ) ::
          {:ok, Req.Response.t()} | {:error, Error.t()}
  defp retry_with_auth(ref, url, headers, opts, resp) do
    creds = Keyword.get(opts, :creds, :anonymous)

    case Auth.parse_challenge(header(resp, "www-authenticate") || "") do
      {:ok, challenge} ->
        with {:ok, token} <- token(ref, challenge, creds, opts) do
          finish(ref, request(url, headers, opts, auth: {:bearer, token}))
        end

      # A Basic-scheme challenge: retry directly with the supplied credentials.
      {:error, :unsupported} ->
        case creds do
          {:basic, user, pass} ->
            finish(ref, request(url, headers, opts, auth: {:basic, "#{user}:#{pass}"}))

          :anonymous ->
            {:error, error(ref, status: 401, reason: :unauthorized)}
        end
    end
  end

  @spec finish(Reference.t(), {:ok, Req.Response.t()} | {:error, term()}) ::
          {:ok, Req.Response.t()} | {:error, Error.t()}
  defp finish(_ref, {:ok, %{status: status} = resp}) when status in 200..299, do: {:ok, resp}

  defp finish(ref, {:ok, resp}),
    do: {:error, error(ref, status: resp.status, reason: :request_failed, body: resp.body)}

  defp finish(ref, {:error, reason}), do: {:error, error(ref, reason: reason)}

  @spec token(Reference.t(), Auth.challenge(), Auth.creds(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  defp token(ref, challenge, creds, opts) do
    case Auth.token(challenge, creds, opts) do
      {:ok, token} -> {:ok, token}
      {:error, auth_error} -> {:error, error(ref, reason: auth_error)}
    end
  end

  @spec request(String.t(), [{String.t(), String.t()}], keyword(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Exception.t()}
  defp request(url, headers, opts, extra) do
    # raw + compressed:false → the body is the exact stored bytes the digest is computed over.
    [
      url: url,
      headers: headers,
      raw: true,
      compressed: false,
      retry: :transient,
      max_retries: Keyword.get(opts, :max_retries, 3)
    ]
    |> Keyword.merge(extra)
    |> Keyword.merge(Keyword.get(opts, :req_options, []))
    |> Req.request()
  end

  @spec decode_manifest(binary(), Reference.t()) :: {:ok, map()} | {:error, Error.t()}
  defp decode_manifest(raw, ref) do
    case JSON.decode(raw) do
      {:ok, json} when is_map(json) -> {:ok, json}
      _ -> {:error, error(ref, reason: :invalid_manifest_json)}
    end
  end

  @spec decode_json(binary(), Reference.t()) :: {:ok, map()} | {:error, Error.t()}
  defp decode_json(raw, ref) do
    case JSON.decode(raw) do
      {:ok, json} when is_map(json) -> {:ok, json}
      _ -> {:error, error(ref, reason: :invalid_json)}
    end
  end

  # Prefer the registry's Docker-Content-Digest (verifying the bytes against it); else compute.
  @spec resolve_digest(Req.Response.t(), binary(), Reference.t()) ::
          {:ok, Digest.t()} | {:error, Error.t()}
  defp resolve_digest(resp, raw, ref) do
    case header(resp, "docker-content-digest") do
      nil ->
        {:ok, Digest.compute(raw)}

      header ->
        with {:ok, digest} <- parse_header_digest(header, ref) do
          case Digest.verify(raw, digest) do
            :ok -> {:ok, digest}
            {:error, :digest_mismatch} -> {:error, error(ref, reason: :manifest_digest_mismatch)}
          end
        end
    end
  end

  @spec parse_header_digest(String.t(), Reference.t()) :: {:ok, Digest.t()} | {:error, Error.t()}
  defp parse_header_digest(header, ref) do
    case Digest.parse(header) do
      {:ok, digest} -> {:ok, digest}
      {:error, _} -> {:error, error(ref, reason: :invalid_content_digest_header)}
    end
  end

  @spec next_link(Req.Response.t(), Reference.t(), keyword()) :: String.t() | nil
  defp next_link(resp, ref, opts) do
    with link when is_binary(link) <- header(resp, "link"),
         [_, path] <- Regex.run(~r/<([^>]+)>\s*;\s*rel="?next"?/, link) do
      # The Link target is registry-relative; resolve against the base.
      base = "#{scheme(opts)}://#{ref.registry}"
      if String.starts_with?(path, "http"), do: path, else: base <> path
    else
      _ -> nil
    end
  end

  @spec url(Reference.t(), String.t(), String.t() | nil, keyword()) :: String.t()
  defp url(ref, kind, reference, opts) do
    base = "#{scheme(opts)}://#{ref.registry}/v2/#{ref.repository}/#{kind}"
    if reference, do: base <> "/" <> reference, else: base
  end

  @spec reference_part(Reference.t()) :: String.t()
  defp reference_part(%Reference{digest: %Digest{} = digest}), do: Digest.to_string(digest)
  defp reference_part(%Reference{tag: tag}) when is_binary(tag), do: tag

  @spec scheme(keyword()) :: String.t()
  defp scheme(opts), do: Keyword.get(opts, :scheme, "https")

  @spec header(Req.Response.t(), String.t()) :: String.t() | nil
  defp header(resp, name), do: resp |> Req.Response.get_header(name) |> List.first()

  @spec error(Reference.t(), keyword()) :: Error.t()
  defp error(ref, fields) do
    struct(%Error{registry: ref.registry, repository: ref.repository}, fields)
  end

  @spec ensure_req!() :: :ok
  defp ensure_req! do
    unless Code.ensure_loaded?(Req) do
      raise RuntimeError,
            "Stevedore.Registry requires the optional :req dependency. " <>
              "Add {:req, \"~> 0.5\"} to your deps to use the docker:// transport."
    end

    :ok
  end
end
