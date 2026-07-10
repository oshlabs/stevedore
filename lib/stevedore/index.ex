defmodule Stevedore.Index do
  @moduledoc """
  An assembled multi-arch image index held in memory: the index manifest plus
  the per-platform `Stevedore.Image` children it points at.

  Produced by `Stevedore.Build.index/2` and consumed by `Stevedore.copy/3`
  exactly like an `Stevedore.Image` (`copy` pushes the children it selects,
  then the index itself). `assemble/2` is the single place that turns a list
  of images into a digest-correct index: each child descriptor's digest/size
  are computed over the child's raw manifest bytes, and its `platform` is
  taken from the child's config.

  Spec: [OCI image-spec, image-index](https://github.com/opencontainers/image-spec/blob/main/image-index.md).
  """

  alias Stevedore.{Descriptor, Digest, Image, Manifest, MediaType}

  @enforce_keys [:manifest, :images]
  defstruct [:manifest, :images, :tag]

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          images: [Image.t()],
          tag: String.t() | nil
        }

  @doc """
  Assembles an index from a non-empty list of `Stevedore.Image`s.

  Each child's descriptor platform comes from its config's `os`/`architecture`.
  `opts`: `:format` (`:oci`/`:docker`, default `:oci`), `:annotations`, `:tag`.
  Errors with `{:bad_input, reason}` when a child has no platform in its
  config (an index entry without one is useless to platform resolution).
  """
  @spec assemble([Image.t(), ...], keyword()) :: {:ok, t()} | {:error, term()}
  def assemble([%Image{} | _] = images, opts \\ []) do
    format = Keyword.get(opts, :format, :oci)

    with {:ok, descriptors} <- child_descriptors(images) do
      index_json =
        %{
          "schemaVersion" => 2,
          "mediaType" => index_media(format),
          "manifests" => Enum.map(descriptors, &Descriptor.to_json/1)
        }
        |> put_annotations(opts[:annotations])

      raw = JSON.encode!(index_json)
      {:ok, manifest} = Manifest.parse(raw, index_media(format))
      {:ok, %__MODULE__{manifest: manifest, images: images, tag: opts[:tag]}}
    end
  end

  @doc "The index's manifest digest."
  @spec digest(t()) :: Digest.t()
  def digest(%__MODULE__{manifest: manifest}), do: manifest.digest

  @doc "Finds the child image whose manifest digest matches `digest`."
  @spec image(t(), Digest.t()) :: {:ok, Image.t()} | {:error, :not_found}
  def image(%__MODULE__{images: images}, %Digest{} = digest) do
    target = Digest.to_string(digest)

    case Enum.find(images, &(Digest.to_string(Image.digest(&1)) == target)) do
      nil -> {:error, :not_found}
      child -> {:ok, child}
    end
  end

  @spec child_descriptors([Image.t()]) :: {:ok, [Descriptor.t()]} | {:error, term()}
  defp child_descriptors(images) do
    Enum.reduce_while(images, {:ok, []}, fn image, {:ok, acc} ->
      case platform(image) do
        nil ->
          {:halt,
           {:error, {:bad_input, "image config has no os/architecture: #{inspect(image)}"}}}

        platform ->
          descriptor = %Descriptor{
            media_type: image.manifest.media_type,
            digest: image.manifest.digest,
            size: byte_size(image.manifest.raw),
            platform: platform
          }

          {:cont, {:ok, [descriptor | acc]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @spec platform(Image.t()) :: Descriptor.platform() | nil
  defp platform(%Image{config: config}) do
    case {config.os, config.architecture} do
      {os, arch} when is_binary(os) and is_binary(arch) ->
        %{os: os, architecture: arch, variant: nil, os_version: nil}

      _ ->
        nil
    end
  end

  @spec index_media(:oci | :docker) :: String.t()
  defp index_media(:docker), do: MediaType.docker_manifest_list()
  defp index_media(_), do: MediaType.oci_index()

  @spec put_annotations(map(), map() | nil) :: map()
  defp put_annotations(json, annotations) when annotations in [nil, %{}], do: json
  defp put_annotations(json, annotations), do: Map.put(json, "annotations", annotations)

  defimpl Inspect do
    def inspect(%Stevedore.Index{images: images} = idx, _opts) do
      platforms =
        Enum.map_join(images, ", ", fn img ->
          "#{img.config.os}/#{img.config.architecture}"
        end)

      "#Stevedore.Index<#{platforms}, #{Stevedore.Digest.short(Stevedore.Index.digest(idx))}>"
    end
  end
end
