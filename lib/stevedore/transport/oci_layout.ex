defmodule Stevedore.Transport.OCILayout do
  @moduledoc """
  The `oci:` transport — an OCI image-layout directory.

  Layout (image-spec): an `oci-layout` marker, a top-level `index.json` mapping tags to manifest
  descriptors, and content-addressed blobs under `blobs/<algo>/<hex>`. Manifests are themselves
  stored as blobs; `index.json` records each with an `org.opencontainers.image.ref.name`
  annotation for its tag. Blob I/O goes through `Stevedore.Store.Local`, whose layout matches.

  Spec: [OCI image-layout](https://github.com/opencontainers/image-spec/blob/main/image-layout.md).
  """

  @behaviour Stevedore.Transport

  alias Stevedore.{Digest, MediaType, Transport}
  alias Stevedore.Store.Local

  @enforce_keys [:path]
  defstruct [:path]

  @type t :: %__MODULE__{path: Path.t()}

  @ref_name "org.opencontainers.image.ref.name"

  @impl true
  @spec get_manifest(t(), Transport.ref()) :: {:ok, Transport.fetched()} | {:error, term()}
  def get_manifest(%__MODULE__{} = t, ref) do
    with {:ok, descriptor} <- find_descriptor(t, ref),
         {:ok, digest} <- Digest.parse(descriptor["digest"]),
         {:ok, raw} <- get_blob(t, digest),
         {:ok, json} <- decode(raw) do
      media_type = descriptor["mediaType"] || json["mediaType"] || MediaType.oci_manifest()
      {:ok, %{media_type: media_type, digest: Digest.compute(raw), raw: raw, json: json}}
    end
  end

  @impl true
  @spec put_manifest(t(), Transport.ref(), binary(), String.t()) ::
          {:ok, Digest.t()} | {:error, term()}
  def put_manifest(%__MODULE__{} = t, ref, raw, media_type) do
    :ok = ensure_layout(t)
    digest = Digest.compute(raw)

    with :ok <- Local.put(t.path, digest, raw) do
      descriptor =
        %{
          "mediaType" => media_type,
          "digest" => Digest.to_string(digest),
          "size" => byte_size(raw)
        }
        |> put_ref_name(ref)

      update_index(t, descriptor, ref)
      {:ok, digest}
    end
  end

  @impl true
  @spec get_blob(t(), Digest.t()) :: {:ok, binary()} | {:error, term()}
  def get_blob(%__MODULE__{} = t, %Digest{} = digest), do: Local.get(t.path, digest)

  @impl true
  @spec put_blob(t(), Digest.t(), iodata()) :: :ok | {:error, term()}
  def put_blob(%__MODULE__{} = t, %Digest{} = digest, data) do
    :ok = ensure_layout(t)
    Local.put(t.path, digest, data)
  end

  @impl true
  @spec has_blob?(t(), Digest.t()) :: boolean()
  def has_blob?(%__MODULE__{} = t, %Digest{} = digest), do: Local.exists?(t.path, digest)

  @impl true
  @spec list_tags(t()) :: {:ok, [String.t()]}
  def list_tags(%__MODULE__{} = t) do
    tags =
      t
      |> read_index()
      |> Map.get("manifests", [])
      |> Enum.map(&get_in(&1, ["annotations", @ref_name]))
      |> Enum.reject(&is_nil/1)

    {:ok, tags}
  end

  @impl true
  @spec delete(t(), Transport.ref()) :: :ok
  def delete(%__MODULE__{} = t, ref) do
    index = read_index(t)
    name = if is_binary(ref), do: ref, else: nil

    manifests =
      Enum.reject(index["manifests"] || [], &(get_in(&1, ["annotations", @ref_name]) == name))

    write_index(t, Map.put(index, "manifests", manifests))
  end

  @spec find_descriptor(t(), Transport.ref()) :: {:ok, map()} | {:error, :not_found}
  defp find_descriptor(%__MODULE__{} = t, ref) do
    manifests = read_index(t)["manifests"] || []

    descriptor =
      cond do
        match?(%Digest{}, ref) -> Enum.find(manifests, &(&1["digest"] == Digest.to_string(ref)))
        is_binary(ref) -> Enum.find(manifests, &(get_in(&1, ["annotations", @ref_name]) == ref))
        ref == nil and length(manifests) == 1 -> hd(manifests)
        true -> nil
      end

    if descriptor, do: {:ok, descriptor}, else: {:error, :not_found}
  end

  @spec put_ref_name(map(), Transport.ref()) :: map()
  defp put_ref_name(descriptor, ref) when is_binary(ref),
    do: Map.put(descriptor, "annotations", %{@ref_name => ref})

  defp put_ref_name(descriptor, _ref), do: descriptor

  # Replace any entry with the same digest or the same tag, then append the new one.
  @spec update_index(t(), map(), Transport.ref()) :: :ok
  defp update_index(%__MODULE__{} = t, descriptor, ref) do
    index = read_index(t)
    name = if is_binary(ref), do: ref, else: nil

    kept =
      Enum.reject(index["manifests"] || [], fn m ->
        m["digest"] == descriptor["digest"] or
          (name != nil and get_in(m, ["annotations", @ref_name]) == name)
      end)

    write_index(t, Map.put(index, "manifests", kept ++ [descriptor]))
  end

  @spec ensure_layout(t()) :: :ok
  defp ensure_layout(%__MODULE__{} = t) do
    File.mkdir_p!(Path.join(t.path, "blobs"))
    marker = Path.join(t.path, "oci-layout")

    unless File.exists?(marker),
      do: File.write!(marker, JSON.encode!(%{"imageLayoutVersion" => "1.0.0"}))

    unless File.exists?(index_path(t)), do: write_index(t, base_index())
    :ok
  end

  @spec read_index(t()) :: map()
  defp read_index(%__MODULE__{} = t) do
    case File.read(index_path(t)) do
      {:ok, raw} -> with {:ok, json} <- JSON.decode(raw), do: json, else: (_ -> base_index())
      _ -> base_index()
    end
  end

  @spec write_index(t(), map()) :: :ok
  defp write_index(%__MODULE__{} = t, index) do
    File.mkdir_p!(t.path)
    File.write!(index_path(t), JSON.encode!(index))
  end

  @spec base_index() :: map()
  defp base_index,
    do: %{"schemaVersion" => 2, "mediaType" => MediaType.oci_index(), "manifests" => []}

  @spec index_path(t()) :: Path.t()
  defp index_path(%__MODULE__{} = t), do: Path.join(t.path, "index.json")

  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, json} when is_map(json) -> {:ok, json}
      _ -> {:error, {:bad_input, "manifest is not a JSON object"}}
    end
  end
end
