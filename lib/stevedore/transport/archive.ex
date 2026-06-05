defmodule Stevedore.Transport.Archive do
  @moduledoc """
  Tar-backed transports: `oci-archive:` (an OCI image layout as a tar) and `docker-archive:`
  (a `docker save` tarball).

  Both are backed by an OCI layout in a temporary work directory: blob and manifest I/O delegate
  to `Stevedore.Transport.OCILayout`, and `finalize/1` (called once at the end of a copy) emits
  the tar — verbatim for `:oci`, converted to the `docker save` layout for `:docker`. Reading
  unpacks the tar into the work dir first, converting from `docker save` when needed.

  Spec: [OCI image-layout](https://github.com/opencontainers/image-spec/blob/main/image-layout.md)
  and the Docker image spec v1.2 `manifest.json`.
  """

  @behaviour Stevedore.Transport

  alias Stevedore.{Archive, Digest, Manifest, MediaType, Transport}
  alias Stevedore.Transport.OCILayout

  @enforce_keys [:path, :format, :work]
  defstruct [:path, :format, :work]

  @type t :: %__MODULE__{path: Path.t(), format: :oci | :docker, work: Path.t()}

  @impl true
  @spec get_manifest(t(), Transport.ref()) :: {:ok, Transport.fetched()} | {:error, term()}
  def get_manifest(%__MODULE__{} = t, ref) do
    with :ok <- ensure_loaded(t), do: OCILayout.get_manifest(layout(t), ref)
  end

  @impl true
  @spec put_manifest(t(), Transport.ref(), binary(), String.t()) ::
          {:ok, Digest.t()} | {:error, term()}
  def put_manifest(%__MODULE__{} = t, ref, raw, media_type) do
    File.mkdir_p!(t.work)
    OCILayout.put_manifest(layout(t), ref, raw, media_type)
  end

  @impl true
  @spec get_blob(t(), Digest.t()) :: {:ok, binary()} | {:error, term()}
  def get_blob(%__MODULE__{} = t, %Digest{} = digest) do
    with :ok <- ensure_loaded(t), do: OCILayout.get_blob(layout(t), digest)
  end

  @impl true
  @spec put_blob(t(), Digest.t(), iodata()) :: :ok | {:error, term()}
  def put_blob(%__MODULE__{} = t, %Digest{} = digest, data) do
    File.mkdir_p!(t.work)
    OCILayout.put_blob(layout(t), digest, data)
  end

  @impl true
  @spec has_blob?(t(), Digest.t()) :: boolean()
  def has_blob?(%__MODULE__{} = t, %Digest{} = digest) do
    ensure_loaded(t)
    OCILayout.has_blob?(layout(t), digest)
  end

  @impl true
  @spec list_tags(t()) :: {:ok, [String.t()]}
  def list_tags(%__MODULE__{} = t) do
    ensure_loaded(t)
    OCILayout.list_tags(layout(t))
  end

  @impl true
  @spec finalize(t()) :: :ok | {:error, term()}
  def finalize(%__MODULE__{format: :oci} = t) do
    File.write!(t.path, Archive.write!(dir_entries(t.work)))
    cleanup(t)
  end

  def finalize(%__MODULE__{format: :docker} = t) do
    with {:ok, tar} <- docker_save_tar(t) do
      File.write!(t.path, tar)
      cleanup(t)
    end
  end

  @spec layout(t()) :: OCILayout.t()
  defp layout(%__MODULE__{work: work}), do: %OCILayout{path: work}

  # Unpack the source tar into the work dir on first read (idempotent via a marker file).
  @spec ensure_loaded(t()) :: :ok | {:error, term()}
  defp ensure_loaded(%__MODULE__{} = t) do
    cond do
      File.exists?(Path.join(t.work, ".loaded")) -> :ok
      not File.regular?(t.path) -> :ok
      true -> load(t)
    end
  end

  @spec load(t()) :: :ok | {:error, term()}
  defp load(%__MODULE__{} = t) do
    with {:ok, tar} <- File.read(t.path),
         {:ok, entries} <- Archive.read(tar) do
      File.mkdir_p!(t.work)

      case t.format do
        :oci -> extract(t.work, entries)
        :docker -> docker_load(t, index_entries(entries))
      end

      File.write!(Path.join(t.work, ".loaded"), "")
      :ok
    end
  end

  # --- docker save <-> OCI layout conversion ---

  @spec docker_load(t(), %{optional(String.t()) => binary()}) :: :ok
  defp docker_load(%__MODULE__{} = t, files) do
    [entry | _] = JSON.decode!(files["manifest.json"])
    config_raw = Map.fetch!(files, entry["Config"])
    config_digest = Digest.compute(config_raw)
    :ok = OCILayout.put_blob(layout(t), config_digest, config_raw)

    layer_descriptors =
      Enum.map(entry["Layers"] || [], fn layer_path ->
        raw = Map.fetch!(files, layer_path)
        digest = Digest.compute(raw)
        :ok = OCILayout.put_blob(layout(t), digest, raw)

        %{
          "mediaType" => MediaType.oci_layer(),
          "size" => byte_size(raw),
          "digest" => Digest.to_string(digest)
        }
      end)

    manifest = %{
      "schemaVersion" => 2,
      "mediaType" => MediaType.oci_manifest(),
      "config" => %{
        "mediaType" => MediaType.oci_config(),
        "size" => byte_size(config_raw),
        "digest" => Digest.to_string(config_digest)
      },
      "layers" => layer_descriptors
    }

    {:ok, _} =
      OCILayout.put_manifest(
        layout(t),
        repo_tag(entry),
        JSON.encode!(manifest),
        MediaType.oci_manifest()
      )

    :ok
  end

  @spec docker_save_tar(t()) :: {:ok, binary()} | {:error, term()}
  defp docker_save_tar(%__MODULE__{} = t) do
    with {:ok, fetched} <- OCILayout.get_manifest(layout(t), nil),
         {:ok, manifest} <- Manifest.parse(fetched.raw, fetched.media_type),
         {:ok, config_desc} <- Manifest.config(manifest),
         {:ok, layer_descs} <- Manifest.layers(manifest),
         {:ok, config_raw} <- OCILayout.get_blob(layout(t), config_desc.digest),
         {:ok, layer_files} <- collect_layers(t, layer_descs) do
      config_name = "#{config_desc.digest.hex}.json"
      layer_names = Enum.map(layer_files, &elem(&1, 0))

      manifest_json =
        JSON.encode!([
          %{"Config" => config_name, "RepoTags" => repo_tags(t), "Layers" => layer_names}
        ])

      entries =
        [tar_file(config_name, config_raw), tar_file("manifest.json", manifest_json)] ++
          Enum.flat_map(layer_files, fn {name, content} ->
            [tar_dir(Path.dirname(name) <> "/"), tar_file(name, content)]
          end)

      {:ok, Archive.write!(entries)}
    end
  end

  @spec collect_layers(t(), [Stevedore.Descriptor.t()]) ::
          {:ok, [{String.t(), binary()}]} | {:error, term()}
  defp collect_layers(%__MODULE__{} = t, descriptors) do
    Enum.reduce_while(descriptors, {:ok, []}, fn desc, {:ok, acc} ->
      case OCILayout.get_blob(layout(t), desc.digest) do
        {:ok, raw} -> {:cont, {:ok, [{"#{desc.digest.hex}/layer.tar", raw} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @spec repo_tag(map()) :: String.t() | nil
  defp repo_tag(entry), do: entry["RepoTags"] |> List.wrap() |> List.first()

  @spec repo_tags(t()) :: [String.t()]
  defp repo_tags(%__MODULE__{} = t) do
    {:ok, tags} = OCILayout.list_tags(layout(t))
    tags
  end

  # --- tar helpers ---

  @spec index_entries([Archive.entry()]) :: %{optional(String.t()) => binary()}
  defp index_entries(entries) do
    for %{type: :regular, name: name, content: content} <- entries, into: %{}, do: {name, content}
  end

  @spec extract(Path.t(), [Archive.entry()]) :: :ok
  defp extract(work, entries) do
    Enum.each(entries, fn entry ->
      full = Path.join(work, entry.name)

      case entry.type do
        :directory ->
          File.mkdir_p!(full)

        :regular ->
          File.mkdir_p!(Path.dirname(full))
          File.write!(full, entry.content || "")

        _ ->
          :ok
      end
    end)
  end

  @spec dir_entries(Path.t()) :: [Archive.entry()]
  defp dir_entries(root), do: walk(root, root)

  @spec walk(Path.t(), Path.t()) :: [Archive.entry()]
  defp walk(root, dir) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      full = Path.join(dir, name)
      rel = Path.relative_to(full, root)

      if File.dir?(full) do
        [tar_dir(rel <> "/") | walk(root, full)]
      else
        [tar_file(rel, File.read!(full))]
      end
    end)
  end

  @spec tar_file(String.t(), binary()) :: Archive.entry()
  defp tar_file(name, content),
    do: %{
      name: name,
      type: :regular,
      mode: 0o644,
      size: byte_size(content),
      linkname: nil,
      content: content
    }

  @spec tar_dir(String.t()) :: Archive.entry()
  defp tar_dir(name),
    do: %{name: name, type: :directory, mode: 0o755, size: 0, linkname: nil, content: nil}

  @spec cleanup(t()) :: :ok
  defp cleanup(%__MODULE__{} = t) do
    File.rm_rf!(t.work)
    :ok
  end
end
