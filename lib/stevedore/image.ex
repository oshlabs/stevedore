defmodule Stevedore.Image do
  @moduledoc """
  An assembled image held in memory: a manifest, its config, the ordered layer descriptors, and
  the blob bytes backing them.

  This is the unit `Stevedore.Build` and `Stevedore.Mutate` produce and that `Stevedore.copy/3`
  consumes (a built image can be copied straight to any transport). `assemble/3` is the single
  place that turns a config plus a list of layers into a digest-correct manifest — it always
  recomputes the config's `rootfs.diff_ids`, the per-layer/per-config sizes and digests, and the
  manifest digest, so callers never hand-maintain them.

  Spec: [OCI image-spec, config](https://github.com/opencontainers/image-spec/blob/main/config.md)
  (the `rootfs.diff_ids` / history relationship) and `manifest.md`.
  """

  alias Stevedore.{Config, Descriptor, Digest, Manifest, MediaType}

  @enforce_keys [:manifest, :config, :layers]
  defstruct [:manifest, :config, :layers, :tag, :referrers, blobs: %{}]

  @typedoc "A layer being assembled: its (compressed) descriptor, uncompressed diff_id, and bytes."
  @type layer :: %{descriptor: Descriptor.t(), diff_id: Digest.t(), blob: binary()}

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          config: Config.t(),
          layers: [Descriptor.t()],
          tag: String.t() | nil,
          referrers: [Descriptor.t()] | nil,
          blobs: %{optional(String.t()) => binary()}
        }

  @doc """
  Assembles an image from a full image-config JSON map and a list of `t:layer/0`.

  Recomputes `rootfs.diff_ids` from the layers, ensures the history length matches, and builds the
  config and manifest blobs with correct sizes and digests. `opts`: `:format` (`:oci`/`:docker`),
  `:annotations` (manifest annotations), `:tag`.
  """
  @spec assemble(map(), [layer()], keyword()) :: {:ok, t()} | {:error, term()}
  def assemble(config_json, layers, opts \\ []) do
    format = Keyword.get(opts, :format, :oci)

    config_json =
      config_json
      |> Map.put("rootfs", %{
        "type" => "layers",
        "diff_ids" => Enum.map(layers, &Digest.to_string(&1.diff_id))
      })
      |> ensure_history(length(layers))

    config_raw = JSON.encode!(config_json)

    with {:ok, config} <- Config.parse(config_raw) do
      config_desc = %Descriptor{
        media_type: config_media(format),
        digest: Digest.compute(config_raw),
        size: byte_size(config_raw)
      }

      layer_descs = Enum.map(layers, & &1.descriptor)

      manifest_json =
        %{
          "schemaVersion" => 2,
          "mediaType" => manifest_media(format),
          "config" => Descriptor.to_json(config_desc),
          "layers" => Enum.map(layer_descs, &Descriptor.to_json/1)
        }
        |> put_annotations(opts[:annotations])

      manifest_raw = JSON.encode!(manifest_json)
      {:ok, manifest} = Manifest.parse(manifest_raw, manifest_media(format))

      blobs =
        [
          {to_string(config_desc.digest), config_raw}
          | Enum.map(layers, &{to_string(&1.descriptor.digest), &1.blob})
        ]
        |> Map.new()

      {:ok,
       %__MODULE__{
         manifest: manifest,
         config: config,
         layers: layer_descs,
         blobs: blobs,
         tag: opts[:tag]
       }}
    end
  end

  @doc "The image's manifest digest."
  @spec digest(t()) :: Digest.t()
  def digest(%__MODULE__{manifest: manifest}), do: manifest.digest

  @doc "Fetches a blob's bytes by digest."
  @spec blob(t(), Digest.t()) :: {:ok, binary()} | {:error, :not_found}
  def blob(%__MODULE__{blobs: blobs}, %Digest{} = digest) do
    case Map.fetch(blobs, to_string(digest)) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :not_found}
    end
  end

  @doc """
  Reconstructs the `t:layer/0` records (descriptor + diff_id + bytes) from an assembled image,
  pairing each layer descriptor with its `rootfs.diff_ids` entry.
  """
  @spec layers(t()) :: [layer()]
  def layers(%__MODULE__{} = image) do
    image.layers
    |> Enum.zip(image.config.rootfs_diff_ids)
    |> Enum.map(fn {desc, diff_id} ->
      %{descriptor: desc, diff_id: diff_id, blob: Map.fetch!(image.blobs, to_string(desc.digest))}
    end)
  end

  @doc "The image's manifest format (`:oci` or `:docker`), inferred from its media type."
  @spec format(t()) :: :oci | :docker
  def format(%__MODULE__{manifest: manifest}) do
    if manifest.media_type == MediaType.docker_manifest(), do: :docker, else: :oci
  end

  @doc "The manifest's annotations, if any."
  @spec annotations(t()) :: map() | nil
  def annotations(%__MODULE__{manifest: manifest}), do: manifest.json["annotations"]

  @spec ensure_history(map(), non_neg_integer()) :: map()
  defp ensure_history(config_json, count) do
    case config_json["history"] do
      history when is_list(history) and length(history) == count -> config_json
      _ -> Map.put(config_json, "history", List.duplicate(%{"created_by" => "stevedore"}, count))
    end
  end

  @spec put_annotations(map(), map() | nil) :: map()
  defp put_annotations(json, annotations) when annotations in [nil, %{}], do: json
  defp put_annotations(json, annotations), do: Map.put(json, "annotations", annotations)

  @spec config_media(:oci | :docker) :: String.t()
  defp config_media(:docker), do: MediaType.docker_config()
  defp config_media(_), do: MediaType.oci_config()

  @spec manifest_media(:oci | :docker) :: String.t()
  defp manifest_media(:docker), do: MediaType.docker_manifest()
  defp manifest_media(_), do: MediaType.oci_manifest()
end
