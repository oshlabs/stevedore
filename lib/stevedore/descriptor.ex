defmodule Stevedore.Descriptor do
  @moduledoc """
  A typed, digest-addressed pointer to content (the OCI *descriptor*).

  Descriptors are how a manifest references its config and layers, and how an index references
  its per-platform manifests: each carries a `media_type`, the `digest` and `size` of the target
  bytes, and optional metadata (`platform`, `annotations`, `urls`, `artifact_type`).

  Spec: [OCI image-spec, descriptor](https://github.com/opencontainers/image-spec/blob/main/descriptor.md).
  """

  alias Stevedore.Digest

  @enforce_keys [:media_type, :digest, :size]
  defstruct [:media_type, :digest, :size, :platform, :annotations, :urls, :artifact_type]

  @type platform :: %{
          os: String.t(),
          architecture: String.t(),
          variant: String.t() | nil,
          os_version: String.t() | nil
        }

  @type t :: %__MODULE__{
          media_type: String.t(),
          digest: Digest.t(),
          size: non_neg_integer(),
          platform: platform() | nil,
          annotations: %{optional(String.t()) => String.t()} | nil,
          urls: [String.t()] | nil,
          artifact_type: String.t() | nil
        }

  @doc """
  Builds a descriptor from a decoded JSON object (string keys, as on the wire).

  ## Examples

      iex> {:ok, d} = Stevedore.Descriptor.from_json(%{
      ...>   "mediaType" => "application/vnd.oci.image.layer.v1.tar+gzip",
      ...>   "digest" => "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      ...>   "size" => 32
      ...> })
      iex> {d.size, d.digest.algorithm}
      {32, :sha256}
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, {:bad_input, term()}}
  def from_json(%{"mediaType" => media_type, "digest" => digest_str, "size" => size})
      when is_binary(media_type) and is_integer(size) do
    with {:ok, digest} <- Digest.parse(digest_str) do
      {:ok, %__MODULE__{media_type: media_type, digest: digest, size: size}}
    end
  end

  def from_json(other), do: {:error, {:bad_input, "invalid descriptor: #{inspect(other)}"}}

  @doc """
  Builds a descriptor from JSON, attaching the optional fields (`platform`, `annotations`,
  `urls`, `artifactType`) present in `json`.
  """
  @spec from_json_full(map()) :: {:ok, t()} | {:error, {:bad_input, term()}}
  def from_json_full(json) do
    with {:ok, descriptor} <- from_json(json) do
      {:ok,
       %{
         descriptor
         | platform: parse_platform(json["platform"]),
           annotations: json["annotations"],
           urls: json["urls"],
           artifact_type: json["artifactType"]
       }}
    end
  end

  @doc """
  Renders a descriptor back to a JSON-ready map (string keys), omitting empty optional fields.

  ## Examples

      iex> d = %Stevedore.Descriptor{media_type: "application/vnd.oci.image.config.v1+json",
      ...>   digest: Stevedore.Digest.compute(""), size: 0}
      iex> Stevedore.Descriptor.to_json(d)["mediaType"]
      "application/vnd.oci.image.config.v1+json"
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = d) do
    %{"mediaType" => d.media_type, "digest" => Digest.to_string(d.digest), "size" => d.size}
    |> put_optional("platform", platform_to_json(d.platform))
    |> put_optional("annotations", d.annotations)
    |> put_optional("urls", d.urls)
    |> put_optional("artifactType", d.artifact_type)
  end

  @spec parse_platform(map() | nil) :: platform() | nil
  defp parse_platform(nil), do: nil

  defp parse_platform(%{"os" => os, "architecture" => arch} = p) do
    %{os: os, architecture: arch, variant: p["variant"], os_version: p["os.version"]}
  end

  defp parse_platform(_), do: nil

  @spec platform_to_json(platform() | nil) :: map() | nil
  defp platform_to_json(nil), do: nil

  defp platform_to_json(p) do
    %{"os" => p.os, "architecture" => p.architecture}
    |> put_optional("variant", p.variant)
    |> put_optional("os.version", p.os_version)
  end

  @spec put_optional(map(), String.t(), term()) :: map()
  defp put_optional(map, _key, value) when value in [nil, %{}, []], do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defimpl Inspect do
    def inspect(%Stevedore.Descriptor{} = d, _opts) do
      platform = if d.platform, do: " #{d.platform.os}/#{d.platform.architecture}", else: ""

      "#Stevedore.Descriptor<#{d.media_type} #{Stevedore.Digest.short(d.digest)} #{d.size}B#{platform}>"
    end
  end
end
