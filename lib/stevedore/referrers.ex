defmodule Stevedore.Referrers do
  @moduledoc """
  Attach artifacts to an image and list them — the OCI 1.1 `subject`/`artifactType` mechanism that
  signatures, SBOMs, and scan results hang off of.

  An artifact is an ordinary manifest carrying a `subject` descriptor pointing at the image it
  refers to. `attach/4` sets that subject and pushes the artifact; `list/3` returns the referrers
  index — via the registry Referrers API (with the `<algo>-<hex>` tag-schema fallback) for
  `docker://`, or by scanning stored `subject` fields for a local registry tree.

  Spec: [distribution-spec, Referrers API](https://github.com/opencontainers/distribution-spec/blob/main/spec.md#listing-referrers)
  and [image-spec, manifest `subject`](https://github.com/opencontainers/image-spec/blob/main/manifest.md).
  """

  alias Stevedore.{Config, Descriptor, Digest, Image, Manifest, MediaType, Reference, Transport}
  alias Stevedore.Transport.{Registry, Static}

  @type artifact ::
          Image.t()
          | %{
              required(:media_type) => String.t(),
              required(:data) => binary(),
              optional(:artifact_type) => String.t()
            }

  @doc """
  Attaches `artifact` to the image identified by `subject` on `transport`, setting the artifact's
  `subject` to the (freshly fetched) subject descriptor and pushing it. Returns the artifact's
  manifest digest.
  """
  @spec attach(Transport.t(), Digest.t(), artifact(), keyword()) ::
          {:ok, Digest.t()} | {:error, term()}
  def attach(transport, %Digest{} = subject, artifact, _opts \\ []) do
    with {:ok, descriptor} <- subject_descriptor(transport, subject) do
      image = artifact |> to_image() |> put_subject(descriptor)

      with {:ok, %{digest: digest}} <- Stevedore.copy(image, {transport, image.tag}) do
        {:ok, digest}
      end
    end
  end

  @doc """
  Lists referrers to `subject` on `transport`, returning the referrers image-index as a
  `t:Stevedore.Manifest.t/0`.
  """
  @spec list(Transport.t(), Digest.t(), keyword()) :: {:ok, Manifest.t()} | {:error, term()}
  def list(transport, subject, opts \\ [])

  def list(%Registry{} = transport, subject, _opts) do
    ref = %Reference{registry: transport.registry, repository: transport.repository}

    with {:ok, %{json: json}} <- Stevedore.Registry.referrers(ref, subject, transport.opts) do
      {:ok, index(descriptors_from_json(json))}
    end
  end

  def list(%Static{} = transport, subject, _opts) do
    {:ok, index(scan(transport, subject))}
  end

  def list(_transport, _subject, _opts), do: {:ok, index([])}

  @doc """
  Builds the referrers index (as a `t:Stevedore.Manifest.t/0`) for `subject` by scanning a local
  registry tree's stored `subject` fields. Used by the registry server's referrers endpoint.
  """
  @spec index_for(Static.t(), Digest.t()) :: Manifest.t()
  def index_for(%Static{} = transport, %Digest{} = subject), do: index(scan(transport, subject))

  # --- artifact construction ---

  @spec to_image(artifact()) :: Image.t()
  defp to_image(%Image{} = image), do: image

  defp to_image(%{media_type: media_type, data: data} = spec) do
    config_blob = "{}"

    config = %Descriptor{
      media_type: MediaType.oci_config(),
      digest: Digest.compute(config_blob),
      size: byte_size(config_blob)
    }

    layer = %Descriptor{
      media_type: media_type,
      digest: Digest.compute(data),
      size: byte_size(data)
    }

    manifest_json = %{
      "schemaVersion" => 2,
      "mediaType" => MediaType.oci_manifest(),
      "artifactType" => spec[:artifact_type] || media_type,
      "config" => Descriptor.to_json(config),
      "layers" => [Descriptor.to_json(layer)]
    }

    {:ok, manifest} = Manifest.parse(JSON.encode!(manifest_json), MediaType.oci_manifest())
    {:ok, config_struct} = Config.parse(config_blob)

    %Image{
      manifest: manifest,
      config: config_struct,
      layers: [layer],
      blobs: %{to_string(config.digest) => config_blob, to_string(layer.digest) => data}
    }
  end

  @spec put_subject(Image.t(), Descriptor.t()) :: Image.t()
  defp put_subject(%Image{} = image, descriptor) do
    json = Map.put(image.manifest.json, "subject", Descriptor.to_json(descriptor))
    {:ok, manifest} = Manifest.parse(JSON.encode!(json), image.manifest.media_type)
    %{image | manifest: manifest}
  end

  @spec subject_descriptor(Transport.t(), Digest.t()) :: {:ok, Descriptor.t()} | {:error, term()}
  defp subject_descriptor(transport, subject) do
    with {:ok, fetched} <- Transport.get_manifest(transport, subject) do
      {:ok,
       %Descriptor{
         media_type: fetched.media_type,
         digest: fetched.digest,
         size: byte_size(fetched.raw)
       }}
    end
  end

  # --- index building ---

  @spec scan(Static.t(), Digest.t()) :: [Descriptor.t()]
  defp scan(transport, subject) do
    target = to_string(subject)

    transport
    |> Static.list_manifest_refs()
    |> Enum.flat_map(fn ref ->
      case Static.get_manifest(transport, ref) do
        {:ok, fetched} -> [fetched]
        _ -> []
      end
    end)
    |> Enum.uniq_by(&to_string(&1.digest))
    |> Enum.flat_map(fn fetched ->
      if get_in(fetched.json, ["subject", "digest"]) == target do
        [
          %Descriptor{
            media_type: fetched.media_type,
            digest: fetched.digest,
            size: byte_size(fetched.raw),
            artifact_type: fetched.json["artifactType"]
          }
        ]
      else
        []
      end
    end)
  end

  @spec descriptors_from_json(map()) :: [Descriptor.t()]
  defp descriptors_from_json(json) do
    for entry <- json["manifests"] || [],
        {:ok, descriptor} <- [Descriptor.from_json_full(entry)],
        do: descriptor
  end

  @spec index([Descriptor.t()]) :: Manifest.t()
  defp index(descriptors) do
    json = %{
      "schemaVersion" => 2,
      "mediaType" => MediaType.oci_index(),
      "manifests" => Enum.map(descriptors, &Descriptor.to_json/1)
    }

    {:ok, manifest} = Manifest.parse(JSON.encode!(json), MediaType.oci_index())
    manifest
  end
end
