defmodule Stevedore.Deploy do
  @moduledoc """
  Turn an image into a **static, read-only registry** a dumb web server can serve.

  `tree/3` copies a source into a `Stevedore.Transport.Static` directory layout
  (`v2/<name>/manifests|blobs/...`) and returns the per-manifest response headers a pull client
  needs but a static server can't infer — `Content-Type` and `Docker-Content-Digest`.
  `nginx_config/2` and `caddy_config/2` emit a server config that serves the tree at `/v2/...`
  with those headers (plus `Docker-Distribution-Api-Version`).

  Spec: [Docker Registry HTTP API v2](https://distribution.github.io/distribution/spec/api/) —
  the headers a pull client requires.
  """

  alias Stevedore.{Digest, MediaType, Transport}
  alias Stevedore.Transport.{Parse, Static}

  @api_version "registry/2.0"

  @typedoc "Per-request-path headers a static server must add for manifests."
  @type headers :: %{optional(String.t()) => %{String.t() => String.t()}}

  @doc """
  Copies `source` into a static registry tree at `out` and returns the manifest header map.

  `opts`: `:name` (repository; derived from a registry source otherwise), and any `Stevedore.copy/3`
  option (`:all`, `:platform`, `:scheme`, `:creds`).
  """
  @spec tree(String.t(), Path.t(), keyword()) :: {:ok, headers()} | {:error, term()}
  def tree(source, out, opts \\ []) do
    with {:ok, {_transport, ref}} <- Parse.parse(source, opts) do
      dest = %Static{path: out, name: opts[:name] || repository(source) || "image"}

      with {:ok, _} <- Stevedore.copy(source, {dest, ref}, copy_opts(opts)) do
        {:ok, header_map(out)}
      end
    end
  end

  @doc "Generates an nginx config serving the tree at `out` as a read-only `/v2` registry."
  @spec nginx_config(Path.t(), keyword()) :: {:ok, String.t()}
  def nginx_config(out, opts \\ []) do
    port = Keyword.get(opts, :port, 5000)

    locations =
      out
      |> manifests()
      |> Enum.map_join("\n", fn m ->
        """
            location = #{m.path} {
              default_type "#{m.content_type}";
              add_header Docker-Content-Digest "#{m.digest}";
              add_header Docker-Distribution-Api-Version "#{@api_version}";
              alias #{m.file};
            }
        """
      end)

    config = """
    events {}
    http {
      server {
        listen #{port};
        root #{Path.expand(out)};

        location = /v2/ {
          add_header Docker-Distribution-Api-Version "#{@api_version}";
          return 200 "";
        }

    #{locations}
        location ~ "^/v2/.+/blobs/(sha256:[a-f0-9]+)$" {
          default_type application/octet-stream;
          add_header Docker-Content-Digest "$1";
        }
      }
    }
    """

    {:ok, config}
  end

  @doc "Generates a Caddy config serving the tree at `out` as a read-only `/v2` registry."
  @spec caddy_config(Path.t(), keyword()) :: {:ok, String.t()}
  def caddy_config(out, opts \\ []) do
    port = Keyword.get(opts, :port, 5000)

    manifest_headers =
      out
      |> manifests()
      |> Enum.map_join("\n", fn m ->
        """
          @m#{:erlang.phash2(m.path)} path #{m.path}
          header @m#{:erlang.phash2(m.path)} Content-Type "#{m.content_type}"
          header @m#{:erlang.phash2(m.path)} Docker-Content-Digest "#{m.digest}"
        """
      end)

    config = """
    :#{port} {
      root * #{Path.expand(out)}
      header /v2/* Docker-Distribution-Api-Version "#{@api_version}"
    #{manifest_headers}
      @blob path_regexp blob ^/v2/.+/blobs/(sha256:[a-f0-9]+)$
      header @blob Content-Type application/octet-stream
      header @blob Docker-Content-Digest "{re.blob.1}"
      file_server
    }
    """

    {:ok, config}
  end

  # --- internals ---

  @spec header_map(Path.t()) :: headers()
  defp header_map(out) do
    out
    |> manifests()
    |> Map.new(fn m ->
      {m.path, %{"Content-Type" => m.content_type, "Docker-Content-Digest" => m.digest}}
    end)
  end

  # Walk <out>/v2/<name>/manifests/* and describe each stored manifest.
  @spec manifests(Path.t()) :: [
          %{path: String.t(), file: Path.t(), content_type: String.t(), digest: String.t()}
        ]
  defp manifests(out) do
    base = Path.join(out, "v2")

    for dir <- manifests_dirs(base),
        name = Path.relative_to(Path.dirname(dir), base),
        file <- File.ls!(dir),
        not String.ends_with?(file, ".mediatype") do
      full = Path.join(dir, file)
      raw = File.read!(full)

      %{
        path: "/v2/#{name}/manifests/#{file}",
        file: Path.expand(full),
        content_type: media_type(full),
        digest: to_string(Digest.compute(raw))
      }
    end
  end

  @spec manifests_dirs(Path.t()) :: [Path.t()]
  defp manifests_dirs(base) do
    base
    |> Path.join("**/manifests")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end

  @spec media_type(Path.t()) :: String.t()
  defp media_type(manifest_file) do
    case File.read(manifest_file <> ".mediatype") do
      {:ok, mt} -> mt
      _ -> MediaType.oci_manifest()
    end
  end

  @spec repository(String.t()) :: String.t() | nil
  defp repository(source) do
    case Parse.parse(source) do
      {:ok, {%Transport.Registry{repository: repository}, _ref}} -> repository
      _ -> nil
    end
  end

  @spec copy_opts(keyword()) :: keyword()
  defp copy_opts(opts),
    do: Keyword.take(opts, [:all, :platform, :platforms, :scheme, :creds, :req_options])
end
