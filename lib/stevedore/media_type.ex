defmodule Stevedore.MediaType do
  @moduledoc """
  The OCI and Docker media-type strings, with classifiers.

  A media type tags what a descriptor points at — a manifest, an index (manifest list), a
  config, or a layer — and, for layers, how the tar is compressed. Stevedore handles both the
  OCI and the legacy Docker schema-2 vocabularies, since real registries serve a mix.

  Spec: [OCI image-spec media-types](https://github.com/opencontainers/image-spec/blob/main/media-types.md)
  and the [Docker image manifest v2 schema 2](https://distribution.github.io/distribution/spec/manifest-v2-2/).
  """

  # --- OCI (image-spec) ---
  @oci_manifest "application/vnd.oci.image.manifest.v1+json"
  @oci_index "application/vnd.oci.image.index.v1+json"
  @oci_config "application/vnd.oci.image.config.v1+json"
  @oci_layer "application/vnd.oci.image.layer.v1.tar"
  @oci_layer_gzip "application/vnd.oci.image.layer.v1.tar+gzip"
  @oci_layer_zstd "application/vnd.oci.image.layer.v1.tar+zstd"

  # --- Docker (distribution schema 2) ---
  @docker_manifest "application/vnd.docker.distribution.manifest.v2+json"
  @docker_manifest_list "application/vnd.docker.distribution.manifest.list.v2+json"
  @docker_config "application/vnd.docker.container.image.v1+json"
  @docker_layer_gzip "application/vnd.docker.image.rootfs.diff.tar.gzip"

  @manifests [@oci_manifest, @docker_manifest]
  @indexes [@oci_index, @docker_manifest_list]
  @configs [@oci_config, @docker_config]
  @layers [@oci_layer, @oci_layer_gzip, @oci_layer_zstd, @docker_layer_gzip]

  @doc "The OCI image manifest media type."
  @spec oci_manifest() :: String.t()
  def oci_manifest, do: @oci_manifest

  @doc "The OCI image index (manifest list) media type."
  @spec oci_index() :: String.t()
  def oci_index, do: @oci_index

  @doc "The OCI image config media type."
  @spec oci_config() :: String.t()
  def oci_config, do: @oci_config

  @doc "The OCI uncompressed layer media type (a plain tar)."
  @spec oci_layer() :: String.t()
  def oci_layer, do: @oci_layer

  @doc "The OCI gzip-compressed layer media type."
  @spec oci_layer_gzip() :: String.t()
  def oci_layer_gzip, do: @oci_layer_gzip

  @doc "The OCI zstd-compressed layer media type."
  @spec oci_layer_zstd() :: String.t()
  def oci_layer_zstd, do: @oci_layer_zstd

  @doc "The Docker schema-2 manifest media type."
  @spec docker_manifest() :: String.t()
  def docker_manifest, do: @docker_manifest

  @doc "The Docker schema-2 manifest list (multi-arch index) media type."
  @spec docker_manifest_list() :: String.t()
  def docker_manifest_list, do: @docker_manifest_list

  @doc "The Docker image config media type."
  @spec docker_config() :: String.t()
  def docker_config, do: @docker_config

  @doc "The Docker gzip-compressed layer media type."
  @spec docker_layer_gzip() :: String.t()
  def docker_layer_gzip, do: @docker_layer_gzip

  @doc "All manifest+index media types, for use in an `Accept` header."
  @spec all_manifest_types() :: [String.t()]
  def all_manifest_types, do: @manifests ++ @indexes

  @doc """
  Whether `media_type` names a single-image manifest (OCI or Docker).

  ## Examples

      iex> Stevedore.MediaType.manifest?("application/vnd.oci.image.manifest.v1+json")
      true

      iex> Stevedore.MediaType.manifest?("application/vnd.oci.image.index.v1+json")
      false
  """
  @spec manifest?(String.t()) :: boolean()
  def manifest?(media_type), do: media_type in @manifests

  @doc """
  Whether `media_type` names a multi-arch index / manifest list.

  ## Examples

      iex> Stevedore.MediaType.index?("application/vnd.docker.distribution.manifest.list.v2+json")
      true
  """
  @spec index?(String.t()) :: boolean()
  def index?(media_type), do: media_type in @indexes

  @doc "Whether `media_type` names an image config."
  @spec config?(String.t()) :: boolean()
  def config?(media_type), do: media_type in @configs

  @doc """
  Whether `media_type` names a layer.

  ## Examples

      iex> Stevedore.MediaType.layer?("application/vnd.docker.image.rootfs.diff.tar.gzip")
      true
  """
  @spec layer?(String.t()) :: boolean()
  def layer?(media_type), do: media_type in @layers

  @doc """
  Whether a layer `media_type` is gzip-compressed (`+gzip` / `.tar.gzip`).

  ## Examples

      iex> Stevedore.MediaType.gzip?("application/vnd.oci.image.layer.v1.tar+gzip")
      true

      iex> Stevedore.MediaType.gzip?("application/vnd.oci.image.layer.v1.tar")
      false
  """
  @spec gzip?(String.t()) :: boolean()
  def gzip?(media_type) do
    String.ends_with?(media_type, "+gzip") or String.ends_with?(media_type, ".tar.gzip")
  end

  @doc """
  Whether a layer `media_type` is zstd-compressed (`+zstd`).

  ## Examples

      iex> Stevedore.MediaType.zstd?("application/vnd.oci.image.layer.v1.tar+zstd")
      true
  """
  @spec zstd?(String.t()) :: boolean()
  def zstd?(media_type), do: String.ends_with?(media_type, "+zstd")
end
