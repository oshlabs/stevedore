defmodule Stevedore.Copy do
  @moduledoc """
  The `copy` primitive: move an image between any two transports, preserving digests.

  `copy` fetches the source manifest, copies the config and every layer blob into the
  destination (skipping blobs already present, and mounting cross-repo on registry→registry
  copies), then writes the manifest **raw** so its digest is unchanged. For a multi-arch index it
  copies the host platform by default, the whole index with `all: true`, or a chosen subset with
  `platforms: [...]` / `platform: "os/arch"`.

  Used via `Stevedore.copy/3`. Endpoints are transport-prefixed strings (see
  `Stevedore.Transport.Parse`) or `{transport, ref}` tuples.

  Spec: [containers-transports(5)](https://github.com/containers/image/blob/main/docs/containers-transports.5.md)
  and the distribution-spec push workflow.
  """

  alias Stevedore.{Digest, Image, Index, Manifest, Transport}
  alias Stevedore.Transport.Parse

  @type endpoint :: String.t() | Image.t() | Index.t() | {Transport.t(), Transport.ref()}

  @doc """
  Copies the image at `source` to `dest`. Returns the destination manifest digest.
  """
  @spec run(endpoint(), endpoint(), keyword()) :: {:ok, %{digest: Digest.t()}} | {:error, term()}
  def run(source, dest, opts \\ []) do
    with {:ok, {src, src_ref}} <- endpoint(source, opts),
         {:ok, {dst, dst_ref}} <- endpoint(dest, opts),
         dst = name_static(dst, src),
         {:ok, fetched} <- Transport.get_manifest(src, src_ref),
         {:ok, digest} <- copy_image(src, dst, dst_ref, fetched, opts),
         :ok <- Transport.finalize(dst) do
      {:ok, %{digest: digest}}
    end
  end

  @spec endpoint(endpoint(), keyword()) ::
          {:ok, {Transport.t(), Transport.ref()}} | {:error, term()}
  defp endpoint(string, opts) when is_binary(string), do: Parse.parse(string, opts)

  defp endpoint(%Image{} = image, _opts),
    do: {:ok, {Transport.Memory.from_image(image), image.tag}}

  defp endpoint(%Index{} = index, _opts),
    do: {:ok, {Transport.Memory.from_index(index), index.tag}}

  defp endpoint({%_{}, _ref} = pair, _opts), do: {:ok, pair}

  @spec copy_image(Transport.t(), Transport.t(), Transport.ref(), Transport.fetched(), keyword()) ::
          {:ok, Digest.t()} | {:error, term()}
  defp copy_image(src, dst, dst_ref, fetched, opts) do
    with {:ok, manifest} <- Manifest.parse(fetched.raw, fetched.media_type) do
      case Manifest.kind(manifest) do
        :manifest -> copy_single(src, dst, dst_ref, fetched, manifest, opts)
        :index -> copy_index(src, dst, dst_ref, fetched, manifest, opts)
      end
    end
  end

  # Copy one image manifest: its config + layers, then the manifest itself at `dst_ref`.
  @spec copy_single(
          Transport.t(),
          Transport.t(),
          Transport.ref(),
          Transport.fetched(),
          Manifest.t(),
          keyword()
        ) ::
          {:ok, Digest.t()} | {:error, term()}
  defp copy_single(src, dst, dst_ref, fetched, manifest, opts) do
    with {:ok, config} <- Manifest.config(manifest),
         {:ok, layers} <- Manifest.layers(manifest),
         :ok <- copy_blobs(src, dst, [config | layers], opts) do
      Transport.put_manifest(dst, dst_ref, fetched.raw, fetched.media_type)
    end
  end

  @spec copy_index(
          Transport.t(),
          Transport.t(),
          Transport.ref(),
          Transport.fetched(),
          Manifest.t(),
          keyword()
        ) ::
          {:ok, Digest.t()} | {:error, term()}
  defp copy_index(src, dst, dst_ref, fetched, manifest, opts) do
    with {:ok, descriptors} <- Manifest.manifests(manifest) do
      case select_children(descriptors, opts) do
        {:single, desc} ->
          with {:ok, child} <- copy_child(src, dst, desc, opts) do
            # Skopeo default: a single platform is written as a plain manifest at the tag.
            Transport.put_manifest(dst, dst_ref, child.raw, child.media_type)
          end

        {:multi, selected} ->
          with :ok <- copy_children(src, dst, selected, opts) do
            Transport.put_manifest(dst, dst_ref, fetched.raw, fetched.media_type)
          end

        {:subset, selected} ->
          with :ok <- copy_children(src, dst, selected, opts) do
            raw = rebuild_index(manifest.json, selected)
            Transport.put_manifest(dst, dst_ref, raw, fetched.media_type)
          end

        {:error, _} = error ->
          error
      end
    end
  end

  # Copy a child manifest of an index (addressed by digest), including its blobs.
  @spec copy_child(Transport.t(), Transport.t(), Stevedore.Descriptor.t(), keyword()) ::
          {:ok, Transport.fetched()} | {:error, term()}
  defp copy_child(src, dst, desc, opts) do
    with {:ok, child} <- Transport.get_manifest(src, desc.digest),
         {:ok, manifest} <- Manifest.parse(child.raw, child.media_type),
         {:ok, config} <- Manifest.config(manifest),
         {:ok, layers} <- Manifest.layers(manifest),
         :ok <- copy_blobs(src, dst, [config | layers], opts),
         {:ok, _} <- Transport.put_manifest(dst, desc.digest, child.raw, child.media_type) do
      {:ok, child}
    end
  end

  @spec copy_children(Transport.t(), Transport.t(), [Stevedore.Descriptor.t()], keyword()) ::
          :ok | {:error, term()}
  defp copy_children(src, dst, descriptors, opts) do
    Enum.reduce_while(descriptors, :ok, fn desc, :ok ->
      case copy_child(src, dst, desc, opts) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @spec copy_blobs(Transport.t(), Transport.t(), [Stevedore.Descriptor.t()], keyword()) ::
          :ok | {:error, term()}
  defp copy_blobs(src, dst, descriptors, opts) do
    Enum.reduce_while(descriptors, :ok, fn desc, :ok ->
      case copy_blob(src, dst, desc.digest, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @spec copy_blob(Transport.t(), Transport.t(), Digest.t(), keyword()) :: :ok | {:error, term()}
  defp copy_blob(src, dst, digest, _opts) do
    cond do
      Transport.has_blob?(dst, digest) ->
        :ok

      mount(src, dst, digest) == :ok ->
        :ok

      true ->
        with {:ok, bytes} <- Transport.get_blob(src, digest),
             do: Transport.put_blob(dst, digest, bytes)
    end
  end

  # Cross-repo mount only applies registry → registry on the same host.
  @spec mount(Transport.t(), Transport.t(), Digest.t()) :: :ok | :not_mounted
  defp mount(
         %Transport.Registry{registry: host} = src,
         %Transport.Registry{registry: host} = dst,
         digest
       ) do
    Transport.Registry.mount(dst, digest, src.repository)
  end

  defp mount(_src, _dst, _digest), do: :not_mounted

  # A Static destination with no repository name borrows it from a registry source.
  @spec name_static(Transport.t(), Transport.t()) :: Transport.t()
  defp name_static(%Transport.Static{name: nil} = dst, %Transport.Registry{repository: repo}) do
    %{dst | name: repo}
  end

  defp name_static(%Transport.Static{name: nil} = dst, _src), do: %{dst | name: "image"}
  defp name_static(dst, _src), do: dst

  @spec select_children([Stevedore.Descriptor.t()], keyword()) ::
          {:single, Stevedore.Descriptor.t()}
          | {:multi, [Stevedore.Descriptor.t()]}
          | {:subset, [Stevedore.Descriptor.t()]}
          | {:error, :no_match}
  defp select_children(descriptors, opts) do
    cond do
      opts[:all] ->
        {:multi, descriptors}

      opts[:platforms] ->
        targets = Enum.map(opts[:platforms], &parse_platform/1)

        {:subset,
         Enum.filter(descriptors, fn d -> Enum.any?(targets, &platform_match?(d.platform, &1)) end)}

      true ->
        target = platform_target(opts)

        case Enum.find(descriptors, &platform_match?(&1.platform, target)) do
          nil -> {:error, :no_match}
          desc -> {:single, desc}
        end
    end
  end

  @spec rebuild_index(map(), [Stevedore.Descriptor.t()]) :: binary()
  defp rebuild_index(index_json, selected) do
    keep = MapSet.new(selected, &Digest.to_string(&1.digest))
    manifests = Enum.filter(index_json["manifests"] || [], &MapSet.member?(keep, &1["digest"]))
    JSON.encode!(Map.put(index_json, "manifests", manifests))
  end

  @spec platform_target(keyword()) :: keyword()
  defp platform_target(opts) do
    case opts[:platform] do
      nil -> Manifest.host_platform()
      p when is_binary(p) -> parse_platform(p)
      p when is_list(p) -> p
    end
  end

  @spec parse_platform(String.t()) :: keyword()
  defp parse_platform(string) do
    case String.split(string, "/") do
      [os, arch, variant] -> [os: os, architecture: arch, variant: variant]
      [os, arch] -> [os: os, architecture: arch]
      [os] -> [os: os]
    end
  end

  @spec platform_match?(Stevedore.Descriptor.platform() | nil, keyword()) :: boolean()
  defp platform_match?(nil, _target), do: false

  defp platform_match?(platform, target) do
    platform.os == target[:os] and platform.architecture == target[:architecture] and
      (target[:variant] == nil or platform.variant == target[:variant])
  end
end
