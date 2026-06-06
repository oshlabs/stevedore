defmodule Stevedore do
  @moduledoc """
  A library-first, daemonless OCI toolkit for Elixir — everything you can do to a container
  image **except run it**.

  Stevedore handles OCI artifacts *at rest* (as bytes): fetch, inspect, copy, mirror, build,
  modify, analyze, sign, verify, and serve images. Running them (namespaces, mounts, cgroups)
  is out of scope.

  ## Layers

  The library is a pure core with optional shells:

    * **Core data types** — `Stevedore.Reference`, `Stevedore.Digest`, `Stevedore.MediaType`,
      `Stevedore.Descriptor`, `Stevedore.Manifest`, `Stevedore.Config`, and `Stevedore.Archive`.
    * **The `docker://` client** — `Stevedore.Registry` (requires the optional `:req` dep) plus
      `Stevedore.Auth` for the bearer-token flow.
    * **The `Stevedore.Store` seam** — content-addressed blob I/O, with `Store.Local` and
      `Store.Memory`.

  The functions below are the high-level verbs. See `docs/EXAMPLES.md` for a cookbook of
  task-oriented recipes.

  Nothing here starts a process; adding `:stevedore` as a dependency is weightless.
  """

  # Stevedore.inspect/2 intentionally shadows the rarely-needed Kernel.inspect/2.
  import Kernel, except: [inspect: 2]

  alias Stevedore.{Config, Copy, Digest, Manifest, Reference, Registry, Transport}
  alias Stevedore.Transport.Parse

  @doc """
  Fetches and parses the manifest for `ref` from its registry.

  Options:

    * `:raw` — return the raw manifest bytes instead of a `t:Stevedore.Manifest.t/0`.
    * `:config` — fetch and parse the image config, returning a `t:Stevedore.Config.t/0`
      (selecting the host platform, or `:platform`, when `ref` is a multi-arch index).
    * `:platform` — a keyword (`os`/`architecture`/`variant`) used with `:config` on an index.
    * plus any `Stevedore.Registry` option (`:creds`, `:scheme`, …).
  """
  @spec inspect(Reference.t(), keyword()) ::
          {:ok, Manifest.t() | binary() | Config.t()} | {:error, term()}
  def inspect(%Reference{} = ref, opts \\ []) do
    with {:ok, fetched} <- Registry.manifest(ref, opts) do
      cond do
        opts[:raw] -> {:ok, fetched.raw}
        opts[:config] -> fetch_config(ref, fetched, opts)
        true -> Manifest.parse(fetched.raw, fetched.media_type)
      end
    end
  end

  @doc "Lists the tags in `ref`'s repository."
  @spec list_tags(Reference.t(), keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def list_tags(%Reference{} = ref, opts \\ []), do: Registry.list_tags(ref, opts)

  @doc """
  Starts the standalone `/v2` registry server (`Stevedore.Server`).

  The only thing in Stevedore that boots a process tree, and only when called. Requires the
  optional `:bandit`/`:plug` deps. See `Stevedore.Server` for options (`:store`, `:port`,
  `:authorize`, …).
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: Stevedore.Server.start_link(opts)

  @doc """
  Copies an image from `source` to `dest`, preserving digests. Returns `{:ok, %{digest: ...}}`.

  Endpoints are transport-prefixed strings (`docker://`, `oci:`, `dir:`, `docker-archive:`,
  `oci-archive:`, `static:`) or `{transport, ref}` tuples. Options: `:all` (copy a whole index),
  `:platform`/`:platforms` (select from an index), plus transport options like `:creds`.

  ## Examples

      Stevedore.copy("docker://alpine:3.20", "oci:./alpine:3.20")
      Stevedore.copy("docker://alpine:3.20", "docker://ghcr.io/me/alpine:3.20", all: true)
  """
  @spec copy(Copy.endpoint(), Copy.endpoint(), keyword()) ::
          {:ok, %{digest: Digest.t()}} | {:error, term()}
  def copy(source, dest, opts \\ []), do: Copy.run(source, dest, opts)

  @doc """
  Copies many images from a declarative list of jobs. Each job is `{source, dest}` or a map with
  `:source`/`:dest` (and optional per-job `:opts`). Returns a result per job.
  """
  @spec sync([{Copy.endpoint(), Copy.endpoint()} | map()], keyword()) :: {:ok, [{term(), term()}]}
  def sync(jobs, opts \\ []) when is_list(jobs) do
    results =
      Enum.map(jobs, fn job ->
        {source, dest, job_opts} = normalize_job(job)
        {job, copy(source, dest, Keyword.merge(opts, job_opts))}
      end)

    {:ok, results}
  end

  @doc """
  Deletes the manifest named by `endpoint` (a transport-prefixed string or `{transport, ref}`).
  """
  @spec delete(Copy.endpoint(), keyword()) :: :ok | {:error, term()}
  def delete(endpoint, opts \\ [])

  def delete(string, opts) when is_binary(string) do
    with {:ok, {transport, ref}} <- Parse.parse(string, opts),
         do: Transport.delete(transport, ref)
  end

  def delete({%_{} = transport, ref}, _opts), do: Transport.delete(transport, ref)

  @doc """
  Computes the digest of a manifest from its raw bytes (or a `t:Stevedore.Manifest.t/0`).

  ## Examples

      iex> digest = Stevedore.manifest_digest(~s({"schemaVersion":2}))
      iex> digest.algorithm
      :sha256
  """
  @spec manifest_digest(binary() | Manifest.t()) :: Digest.t()
  def manifest_digest(%Manifest{raw: raw}), do: Digest.compute(raw)
  def manifest_digest(raw) when is_binary(raw), do: Digest.compute(raw)

  @spec normalize_job({Copy.endpoint(), Copy.endpoint()} | map()) ::
          {Copy.endpoint(), Copy.endpoint(), keyword()}
  defp normalize_job({source, dest}), do: {source, dest, []}

  defp normalize_job(%{source: source, dest: dest} = job),
    do: {source, dest, Map.get(job, :opts, [])}

  # Resolve `ref` to a single image manifest (selecting a platform from an index), fetch its
  # config descriptor's blob, and parse it.
  @spec fetch_config(Reference.t(), map(), keyword()) :: {:ok, Config.t()} | {:error, term()}
  defp fetch_config(ref, fetched, opts) do
    with {:ok, manifest} <- Manifest.parse(fetched.raw, fetched.media_type),
         {:ok, manifest, image_ref} <- resolve_image(ref, manifest, opts),
         {:ok, descriptor} <- Manifest.config(manifest),
         {:ok, bytes} <- Registry.blob(image_ref, descriptor.digest, opts) do
      Config.parse(bytes)
    end
  end

  @spec resolve_image(Reference.t(), Manifest.t(), keyword()) ::
          {:ok, Manifest.t(), Reference.t()} | {:error, term()}
  defp resolve_image(ref, manifest, opts) do
    case Manifest.kind(manifest) do
      :manifest ->
        {:ok, manifest, ref}

      :index ->
        with {:ok, descriptor} <- Manifest.select(manifest, opts[:platform] || []),
             image_ref = %{ref | tag: nil, digest: descriptor.digest},
             {:ok, fetched} <- Registry.manifest(image_ref, opts),
             {:ok, image_manifest} <- Manifest.parse(fetched.raw, fetched.media_type) do
          {:ok, image_manifest, image_ref}
        end
    end
  end
end
