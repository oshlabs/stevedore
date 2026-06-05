defmodule Stevedore.Manifest do
  @moduledoc """
  An image manifest **or** an image index (multi-arch manifest list).

  The decoded `json` is kept alongside the **raw bytes** it was parsed from, because a manifest's
  digest is computed over those exact bytes — re-serializing JSON would change the digest. Always
  move manifests by their `raw` field.

  Handles both OCI and Docker schema-2 vocabularies, and recognizes (read-only) legacy Docker
  schema-1 manifests.

  Spec: [OCI manifest](https://github.com/opencontainers/image-spec/blob/main/manifest.md) and
  [image-index](https://github.com/opencontainers/image-spec/blob/main/image-index.md).
  """

  alias Stevedore.{Descriptor, Digest, MediaType}

  @enforce_keys [:media_type, :raw, :json]
  defstruct [:media_type, :raw, :json, :digest]

  @type kind :: :manifest | :index

  @type t :: %__MODULE__{
          media_type: String.t(),
          raw: binary(),
          json: map(),
          digest: Digest.t() | nil
        }

  @doc """
  Parses raw manifest bytes, using `content_type` (the registry's `Content-Type`) when given and
  otherwise sniffing the media type from the JSON. The `digest` is computed over `raw`.

  ## Examples

      iex> raw = ~s({"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]})
      iex> {:ok, m} = Stevedore.Manifest.parse(raw)
      iex> Stevedore.Manifest.kind(m)
      :index
  """
  @spec parse(binary(), String.t() | nil) :: {:ok, t()} | {:error, {:bad_input, term()}}
  def parse(raw, content_type \\ nil) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, json} when is_map(json) ->
        media_type = detect_media_type(json, content_type)

        {:ok,
         %__MODULE__{media_type: media_type, raw: raw, json: json, digest: Digest.compute(raw)}}

      _ ->
        {:error, {:bad_input, "manifest is not a JSON object"}}
    end
  end

  @doc """
  Whether the manifest is a single image (`:manifest`) or a multi-arch index (`:index`).
  """
  @spec kind(t()) :: kind()
  def kind(%__MODULE__{media_type: mt, json: json}) do
    cond do
      MediaType.index?(mt) -> :index
      MediaType.manifest?(mt) -> :manifest
      Map.has_key?(json, "manifests") -> :index
      true -> :manifest
    end
  end

  @doc "The config descriptor of an image manifest."
  @spec config(t()) :: {:ok, Descriptor.t()} | {:error, :not_a_manifest | {:bad_input, term()}}
  def config(%__MODULE__{json: json} = m) do
    case kind(m) do
      :manifest -> Descriptor.from_json_full(json["config"] || %{})
      :index -> {:error, :not_a_manifest}
    end
  end

  @doc "The ordered layer descriptors of an image manifest."
  @spec layers(t()) :: {:ok, [Descriptor.t()]} | {:error, :not_a_manifest | {:bad_input, term()}}
  def layers(%__MODULE__{json: json} = m) do
    case kind(m) do
      :manifest -> map_descriptors(json["layers"] || [])
      :index -> {:error, :not_a_manifest}
    end
  end

  @doc "The per-platform manifest descriptors of an index."
  @spec manifests(t()) :: {:ok, [Descriptor.t()]} | {:error, :not_an_index | {:bad_input, term()}}
  def manifests(%__MODULE__{json: json} = m) do
    case kind(m) do
      :index -> map_descriptors(json["manifests"] || [])
      :manifest -> {:error, :not_an_index}
    end
  end

  @doc """
  Selects the manifest descriptor from an index matching a platform.

  `platform` is a keyword of `:os`, `:architecture`, and optional `:variant`; it defaults to the
  host platform. Errors with `:not_an_index` for a single manifest and `:no_match` when no entry
  matches.

  ## Examples

      iex> raw = ~s({"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
      ...>   {"mediaType":"application/vnd.oci.image.manifest.v1+json","size":1,
      ...>    "digest":"sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      ...>    "platform":{"os":"linux","architecture":"arm64"}}]})
      iex> {:ok, m} = Stevedore.Manifest.parse(raw)
      iex> {:ok, d} = Stevedore.Manifest.select(m, os: "linux", architecture: "arm64")
      iex> d.platform.architecture
      "arm64"
  """
  @spec select(t(), keyword()) ::
          {:ok, Descriptor.t()} | {:error, :no_match | :not_an_index | {:bad_input, term()}}
  def select(%__MODULE__{} = m, platform \\ []) do
    target = Keyword.merge(host_platform(), platform)

    with {:ok, descriptors} <- manifests(m) do
      case Enum.find(descriptors, &platform_match?(&1.platform, target)) do
        nil -> {:error, :no_match}
        descriptor -> {:ok, descriptor}
      end
    end
  end

  @doc """
  The host platform as a keyword (`os`, `architecture`), mapping the BEAM's architecture string
  to OCI/Go naming (`x86_64` → `amd64`, `aarch64` → `arm64`, …).
  """
  @spec host_platform() :: keyword()
  def host_platform do
    os =
      case :os.type() do
        {:unix, name} -> Atom.to_string(name)
        {:win32, _} -> "windows"
      end

    [os: os, architecture: host_arch()]
  end

  @spec detect_media_type(map(), String.t() | nil) :: String.t()
  defp detect_media_type(json, content_type) do
    cond do
      is_binary(content_type) and recognized?(content_type) -> content_type
      is_binary(json["mediaType"]) -> json["mediaType"]
      Map.has_key?(json, "manifests") -> MediaType.oci_index()
      true -> MediaType.oci_manifest()
    end
  end

  @spec recognized?(String.t()) :: boolean()
  defp recognized?(mt), do: MediaType.manifest?(mt) or MediaType.index?(mt)

  @spec map_descriptors([map()]) :: {:ok, [Descriptor.t()]} | {:error, {:bad_input, term()}}
  defp map_descriptors(list) do
    Enum.reduce_while(list, {:ok, []}, fn json, {:ok, acc} ->
      case Descriptor.from_json_full(json) do
        {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @spec platform_match?(Descriptor.platform() | nil, keyword()) :: boolean()
  defp platform_match?(nil, _target), do: false

  defp platform_match?(platform, target) do
    platform.os == target[:os] and platform.architecture == target[:architecture] and
      variant_match?(platform.variant, target[:variant])
  end

  # A requested variant must match; if none requested, any variant is acceptable.
  @spec variant_match?(String.t() | nil, String.t() | nil) :: boolean()
  defp variant_match?(_actual, nil), do: true
  defp variant_match?(actual, requested), do: actual == requested

  @spec host_arch() :: String.t()
  defp host_arch do
    arch =
      :erlang.system_info(:system_architecture) |> List.to_string() |> String.split("-") |> hd()

    case arch do
      "x86_64" -> "amd64"
      "amd64" -> "amd64"
      "aarch64" -> "arm64"
      "arm64" -> "arm64"
      "armv7l" -> "arm"
      "armv7" -> "arm"
      "i386" -> "386"
      "i686" -> "386"
      "ppc64le" -> "ppc64le"
      "s390x" -> "s390x"
      "riscv64" -> "riscv64"
      other -> other
    end
  end
end
