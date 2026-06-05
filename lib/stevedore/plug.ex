if Code.ensure_loaded?(Plug) do
  defmodule Stevedore.Plug do
    @moduledoc """
    A `Plug` implementing the OCI/Docker Distribution **v2 registry API**.

    Mount it in a host router or run it standalone via `Stevedore.start_link/1`. Storage is a
    directory tree (the `Stevedore.Transport.Static` layout) given as `:store`; in-progress blob
    uploads live in a `Stevedore.Server.Uploads` process given as `:uploads`. Authn/authz is the
    host's responsibility through the `:authorize` seam.

    Endpoints: version check, manifest GET/HEAD/PUT/DELETE, blob GET/HEAD/DELETE, chunked blob
    upload sessions (with monolithic and cross-repo mount shortcuts), `_catalog`, `tags/list`, a
    stub referrers endpoint, and a `/token` endpoint for the standalone case.

    ## Options

      * `:store` — filesystem root for registry data (required)
      * `:uploads` — the `Stevedore.Server.Uploads` server (name or pid, required for pushes)
      * `:authorize` — `(conn, action, scope -> :ok | {:error, :unauthorized})` where `action` is
        `:pull | :push | :delete`. Default: allow pull, deny writes.
      * `:realm` — token realm advertised in `WWW-Authenticate` (default: derived from the request)

    Spec: [distribution-spec](https://github.com/opencontainers/distribution-spec/blob/main/spec.md).
    """

    @behaviour Plug

    import Plug.Conn

    alias Stevedore.{Digest, Manifest, MediaType}
    alias Stevedore.Server.Uploads
    alias Stevedore.Transport.Static

    @api_version "registry/2.0"
    @max_chunk 8_000_000

    @impl true
    def init(opts) do
      %{
        store: Keyword.fetch!(opts, :store),
        uploads: Keyword.get(opts, :uploads, Uploads),
        authorize: Keyword.get(opts, :authorize, &default_authorize/3),
        realm: Keyword.get(opts, :realm)
      }
    end

    @impl true
    def call(%Plug.Conn{path_info: ["token"]} = conn, _opts) do
      json(conn, 200, %{"token" => "stevedore", "access_token" => "stevedore"})
    end

    def call(conn, opts) do
      conn = fetch_query_params(conn)
      route(conn.method, parse_path(conn.path_info), conn, opts)
    end

    # --- routing ---

    @spec route(String.t(), term(), Plug.Conn.t(), map()) :: Plug.Conn.t()
    defp route("GET", :base, conn, _opts), do: version(conn)
    defp route("HEAD", :base, conn, _opts), do: version(conn)

    defp route(method, {:manifest, name, ref}, conn, opts) when method in ["GET", "HEAD"],
      do:
        with_auth(conn, :pull, name, opts, fn -> get_manifest(conn, opts, name, ref, method) end)

    defp route("PUT", {:manifest, name, ref}, conn, opts),
      do: with_auth(conn, :push, name, opts, fn -> put_manifest(conn, opts, name, ref) end)

    defp route("DELETE", {:manifest, name, ref}, conn, opts),
      do: with_auth(conn, :delete, name, opts, fn -> delete_manifest(conn, opts, name, ref) end)

    defp route(method, {:blob, name, digest}, conn, opts) when method in ["GET", "HEAD"],
      do: with_auth(conn, :pull, name, opts, fn -> get_blob(conn, opts, name, digest, method) end)

    defp route("DELETE", {:blob, name, digest}, conn, opts),
      do: with_auth(conn, :delete, name, opts, fn -> delete_blob(conn, opts, name, digest) end)

    defp route("POST", {:upload_start, name}, conn, opts),
      do: with_auth(conn, :push, name, opts, fn -> upload_start(conn, opts, name) end)

    defp route("PATCH", {:upload, name, uuid}, conn, opts),
      do: with_auth(conn, :push, name, opts, fn -> upload_chunk(conn, opts, name, uuid) end)

    defp route("PUT", {:upload, name, uuid}, conn, opts),
      do: with_auth(conn, :push, name, opts, fn -> upload_finish(conn, opts, name, uuid) end)

    defp route("GET", {:upload, name, uuid}, conn, opts),
      do: with_auth(conn, :push, name, opts, fn -> upload_status(conn, opts, name, uuid) end)

    defp route("DELETE", {:upload, name, uuid}, conn, opts),
      do: with_auth(conn, :push, name, opts, fn -> upload_cancel(conn, opts, uuid) end)

    defp route("GET", {:tags, name}, conn, opts),
      do: with_auth(conn, :pull, name, opts, fn -> tags_list(conn, opts, name) end)

    defp route("GET", :catalog, conn, opts),
      do: with_auth(conn, :pull, "", opts, fn -> catalog(conn, opts) end)

    defp route("GET", {:referrers, _name, _digest}, conn, _opts), do: referrers(conn)

    defp route(_method, _parsed, conn, _opts),
      do: error(conn, 404, "UNSUPPORTED", "unsupported request")

    # --- handlers ---

    defp version(conn) do
      conn
      |> put_resp_header("docker-distribution-api-version", @api_version)
      |> send_resp(200, "")
    end

    defp get_manifest(conn, opts, name, ref, method) do
      case Static.get_manifest(static(opts, name), ref) do
        {:ok, fetched} ->
          conn
          |> put_resp_content_type(fetched.media_type, nil)
          |> put_resp_header("docker-content-digest", to_string(fetched.digest))
          |> send_resp(200, if(method == "HEAD", do: "", else: fetched.raw))

        {:error, _} ->
          error(conn, 404, "MANIFEST_UNKNOWN", "manifest unknown")
      end
    end

    defp put_manifest(conn, opts, name, ref) do
      {:ok, body, conn} = read_all(conn)
      digest = Digest.compute(body)
      content_type = req_header(conn, "content-type") || MediaType.oci_manifest()
      static = static(opts, name)

      cond do
        digest_ref?(ref) and ref != to_string(digest) ->
          error(conn, 400, "DIGEST_INVALID", "provided digest did not match content")

        (missing = missing_reference(static, body, content_type)) != nil ->
          error(conn, 404, "BLOB_UNKNOWN", "referenced blob #{missing} is unknown")

        true ->
          {:ok, _} = Static.put_manifest(static, ref, body, content_type)

          conn
          |> put_resp_header("docker-content-digest", to_string(digest))
          |> put_resp_header("location", "/v2/#{name}/manifests/#{to_string(digest)}")
          |> send_resp(201, "")
      end
    end

    defp delete_manifest(conn, opts, name, ref) do
      :ok = Static.delete(static(opts, name), ref)
      send_resp(conn, 202, "")
    end

    defp get_blob(conn, opts, name, digest_str, method) do
      with {:ok, digest} <- parse_digest(digest_str),
           {:ok, bytes} <- Static.get_blob(static(opts, name), digest) do
        conn
        |> put_resp_content_type("application/octet-stream", nil)
        |> put_resp_header("docker-content-digest", to_string(digest))
        |> send_resp(200, if(method == "HEAD", do: "", else: bytes))
      else
        _ -> error(conn, 404, "BLOB_UNKNOWN", "blob unknown")
      end
    end

    defp delete_blob(conn, opts, name, digest_str) do
      case parse_digest(digest_str) do
        {:ok, digest} ->
          :ok = Static.delete_blob(static(opts, name), digest)
          send_resp(conn, 202, "")

        :error ->
          error(conn, 400, "DIGEST_INVALID", "invalid digest")
      end
    end

    defp upload_start(conn, opts, name) do
      static = static(opts, name)

      cond do
        conn.query_params["mount"] && conn.query_params["from"] ->
          mount(conn, opts, name, conn.query_params["mount"], conn.query_params["from"])

        conn.query_params["digest"] ->
          monolithic(conn, static, name, conn.query_params["digest"])

        true ->
          {:ok, uuid} = Uploads.create(opts.uploads)

          conn
          |> upload_headers(name, uuid, 0)
          |> send_resp(202, "")
      end
    end

    defp mount(conn, opts, name, mount, from) do
      with {:ok, digest} <- parse_digest(mount),
           true <- Static.has_blob?(static(opts, from), digest),
           {:ok, bytes} <- Static.get_blob(static(opts, from), digest),
           :ok <- Static.put_blob(static(opts, name), digest, bytes) do
        conn
        |> put_resp_header("docker-content-digest", to_string(digest))
        |> put_resp_header("location", "/v2/#{name}/blobs/#{to_string(digest)}")
        |> send_resp(201, "")
      else
        # Mount declined: fall back to a normal upload session.
        _ ->
          {:ok, uuid} = Uploads.create(opts.uploads)
          conn |> upload_headers(name, uuid, 0) |> send_resp(202, "")
      end
    end

    defp monolithic(conn, static, name, digest_str) do
      {:ok, body, conn} = read_all(conn)

      with {:ok, digest} <- parse_digest(digest_str),
           :ok <- verify(body, digest),
           :ok <- Static.put_blob(static, digest, body) do
        conn
        |> put_resp_header("docker-content-digest", to_string(digest))
        |> put_resp_header("location", "/v2/#{name}/blobs/#{to_string(digest)}")
        |> send_resp(201, "")
      else
        _ -> error(conn, 400, "DIGEST_INVALID", "digest did not match content")
      end
    end

    defp upload_chunk(conn, opts, name, uuid) do
      {:ok, body, conn} = read_all(conn)

      case Uploads.append(opts.uploads, uuid, body) do
        {:ok, size} -> conn |> upload_headers(name, uuid, size) |> send_resp(202, "")
        {:error, :unknown_session} -> error(conn, 404, "BLOB_UPLOAD_UNKNOWN", "upload unknown")
      end
    end

    defp upload_finish(conn, opts, name, uuid) do
      {:ok, body, conn} = read_all(conn)

      with {:ok, _size} <- Uploads.append(opts.uploads, uuid, body),
           {:ok, data} <- Uploads.finish(opts.uploads, uuid),
           {:ok, digest} <- parse_digest(conn.query_params["digest"] || ""),
           :ok <- verify(data, digest),
           :ok <- Static.put_blob(static(opts, name), digest, data) do
        conn
        |> put_resp_header("docker-content-digest", to_string(digest))
        |> put_resp_header("location", "/v2/#{name}/blobs/#{to_string(digest)}")
        |> send_resp(201, "")
      else
        {:error, :unknown_session} -> error(conn, 404, "BLOB_UPLOAD_UNKNOWN", "upload unknown")
        _ -> error(conn, 400, "DIGEST_INVALID", "digest did not match content")
      end
    end

    defp upload_status(conn, opts, name, uuid) do
      case Uploads.size(opts.uploads, uuid) do
        {:ok, size} -> conn |> upload_headers(name, uuid, size) |> send_resp(204, "")
        {:error, :unknown_session} -> error(conn, 404, "BLOB_UPLOAD_UNKNOWN", "upload unknown")
      end
    end

    defp upload_cancel(conn, opts, uuid) do
      :ok = Uploads.cancel(opts.uploads, uuid)
      send_resp(conn, 204, "")
    end

    defp tags_list(conn, opts, name) do
      {:ok, tags} = Static.list_tags(static(opts, name))
      {page, next} = paginate(tags, conn.query_params)

      conn
      |> maybe_link_header(next, "/v2/#{name}/tags/list", conn.query_params)
      |> json(200, %{"name" => name, "tags" => page})
    end

    defp catalog(conn, opts) do
      {page, next} = paginate(repositories(opts.store), conn.query_params)

      conn
      |> maybe_link_header(next, "/v2/_catalog", conn.query_params)
      |> json(200, %{"repositories" => page})
    end

    defp referrers(conn) do
      empty = %{"schemaVersion" => 2, "mediaType" => MediaType.oci_index(), "manifests" => []}
      conn |> put_resp_content_type(MediaType.oci_index()) |> json(200, empty)
    end

    # --- auth ---

    @spec with_auth(Plug.Conn.t(), atom(), String.t(), map(), (-> Plug.Conn.t())) :: Plug.Conn.t()
    defp with_auth(conn, action, name, opts, fun) do
      scope = "repository:#{name}:#{scope_action(action)}"

      case opts.authorize.(conn, action, scope) do
        :ok -> fun.()
        {:error, :unauthorized} -> unauthorized(conn, opts, scope)
      end
    end

    defp scope_action(:pull), do: "pull"
    defp scope_action(:push), do: "push,pull"
    defp scope_action(:delete), do: "delete"

    defp default_authorize(_conn, :pull, _scope), do: :ok
    defp default_authorize(_conn, _action, _scope), do: {:error, :unauthorized}

    defp unauthorized(conn, opts, scope) do
      realm = opts.realm || "#{conn.scheme}://#{conn.host}:#{conn.port}/token"
      challenge = ~s(Bearer realm="#{realm}",service="#{conn.host}",scope="#{scope}")

      conn
      |> put_resp_header("www-authenticate", challenge)
      |> error(401, "UNAUTHORIZED", "authentication required")
    end

    # --- path parsing ---

    @spec parse_path([String.t()]) :: term()
    defp parse_path(["v2"]), do: :base
    defp parse_path(["v2", ""]), do: :base
    defp parse_path(["v2", "_catalog"]), do: :catalog

    defp parse_path(["v2" | rest]) do
      cond do
        (r = split_on(rest, "manifests")) != :nomatch ->
          {name, after_} = r
          {:manifest, name, List.first(after_)}

        (r = split_on(rest, "blobs")) != :nomatch ->
          {name, after_} = r
          blob_route(name, after_)

        (r = split_on(rest, "tags")) != :nomatch ->
          {name, after_} = r
          if after_ == ["list"], do: {:tags, name}, else: :unknown

        (r = split_on(rest, "referrers")) != :nomatch ->
          {name, after_} = r
          {:referrers, name, List.first(after_)}

        true ->
          :unknown
      end
    end

    defp parse_path(_), do: :unknown

    defp blob_route(name, ["uploads"]), do: {:upload_start, name}
    defp blob_route(name, ["uploads", ""]), do: {:upload_start, name}
    defp blob_route(name, ["uploads", uuid]), do: {:upload, name, uuid}
    defp blob_route(name, [digest]), do: {:blob, name, digest}
    defp blob_route(_name, _), do: :unknown

    # Split segments around `marker`: {"name/before", [after...]} or :nomatch.
    @spec split_on([String.t()], String.t()) :: {String.t(), [String.t()]} | :nomatch
    defp split_on(segments, marker) do
      case Enum.split_while(segments, &(&1 != marker)) do
        {before, [^marker | after_]} when before != [] -> {Enum.join(before, "/"), after_}
        _ -> :nomatch
      end
    end

    # --- helpers ---

    defp static(opts, name), do: %Static{path: opts.store, name: name}

    defp upload_headers(conn, name, uuid, size) do
      range = if size == 0, do: "0-0", else: "0-#{size - 1}"

      conn
      |> put_resp_header("location", "/v2/#{name}/blobs/uploads/#{uuid}")
      |> put_resp_header("docker-upload-uuid", uuid)
      |> put_resp_header("range", range)
    end

    # Returns the digest string of the first referenced blob that is absent, or nil if all present.
    @spec missing_reference(Static.t(), binary(), String.t()) :: String.t() | nil
    defp missing_reference(static, raw, content_type) do
      with {:ok, manifest} <- Manifest.parse(raw, content_type) do
        case Manifest.kind(manifest) do
          :manifest -> first_missing(static, image_blob_digests(manifest))
          # Index children are validated as manifests, not blobs.
          :index -> first_missing_manifest(static, manifest)
        end
      else
        _ -> nil
      end
    end

    defp image_blob_digests(manifest) do
      {:ok, config} = Manifest.config(manifest)
      {:ok, layers} = Manifest.layers(manifest)
      Enum.map([config | layers], & &1.digest)
    end

    defp first_missing(static, digests) do
      Enum.find_value(digests, fn d ->
        if Static.has_blob?(static, d), do: nil, else: to_string(d)
      end)
    end

    defp first_missing_manifest(static, index) do
      {:ok, children} = Manifest.manifests(index)

      Enum.find_value(children, fn child ->
        case Static.get_manifest(static, child.digest) do
          {:ok, _} -> nil
          _ -> to_string(child.digest)
        end
      end)
    end

    defp repositories(root) do
      base = Path.join(root, "v2")
      find_repos(base, base)
    end

    defp find_repos(base, dir) do
      case File.ls(dir) do
        {:ok, entries} ->
          Enum.flat_map(entries, fn entry ->
            full = Path.join(dir, entry)

            cond do
              not File.dir?(full) -> []
              File.dir?(Path.join(full, "manifests")) -> [Path.relative_to(full, base)]
              true -> find_repos(base, full)
            end
          end)

        _ ->
          []
      end
    end

    @spec paginate([String.t()], map()) :: {[String.t()], String.t() | nil}
    defp paginate(items, query) do
      items =
        items
        |> Enum.sort()
        |> then(fn sorted ->
          if query["last"], do: Enum.filter(sorted, &(&1 > query["last"])), else: sorted
        end)

      case parse_int(query["n"]) do
        nil ->
          {items, nil}

        n ->
          page = Enum.take(items, n)
          next = if length(items) > n, do: List.last(page), else: nil
          {page, next}
      end
    end

    defp maybe_link_header(conn, nil, _path, _query), do: conn

    defp maybe_link_header(conn, last, path, query) do
      n = query["n"]
      link = "<#{path}?last=#{URI.encode(last)}&n=#{n}>; rel=\"next\""
      put_resp_header(conn, "link", link)
    end

    @spec read_all(Plug.Conn.t()) :: {:ok, binary(), Plug.Conn.t()} | {:error, term()}
    defp read_all(conn, acc \\ []) do
      case read_body(conn, length: @max_chunk) do
        {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary([acc, chunk]), conn}
        {:more, chunk, conn} -> read_all(conn, [acc, chunk])
        {:error, reason} -> {:error, reason}
      end
    end

    defp verify(data, digest) do
      case Digest.verify(data, digest) do
        :ok -> :ok
        {:error, _} -> :error
      end
    end

    defp parse_digest(str) do
      case Digest.parse(str) do
        {:ok, digest} -> {:ok, digest}
        {:error, _} -> :error
      end
    end

    defp digest_ref?(ref), do: match?({:ok, _}, Digest.parse(ref))

    defp req_header(conn, name), do: conn |> get_req_header(name) |> List.first()

    defp parse_int(nil), do: nil

    defp parse_int(str) do
      case Integer.parse(str) do
        {n, _} when n >= 0 -> n
        _ -> nil
      end
    end

    defp json(conn, status, data) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, JSON.encode!(data))
    end

    defp error(conn, status, code, message) do
      json(conn, status, %{"errors" => [%{"code" => code, "message" => message}]})
    end
  end
end
