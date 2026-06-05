defmodule Stevedore.Transport.Dir do
  @moduledoc """
  The `dir:` transport — Skopeo's flat directory of a single image.

  Holds `manifest.json` (the raw manifest bytes) and one file per blob, named by the digest hex.
  Because it stores a single image, the `ref` argument is ignored and `list_tags/1` is empty. The
  media type is sniffed from the manifest bytes on read.

  Spec: containers-image `dir` transport
  ([containers-transports(5)](https://github.com/containers/image/blob/main/docs/containers-transports.5.md)).
  """

  @behaviour Stevedore.Transport

  alias Stevedore.{Digest, Manifest, Transport}

  @enforce_keys [:path]
  defstruct [:path]

  @type t :: %__MODULE__{path: Path.t()}

  @manifest "manifest.json"

  @impl true
  @spec get_manifest(t(), Transport.ref()) :: {:ok, Transport.fetched()} | {:error, term()}
  def get_manifest(%__MODULE__{} = t, _ref) do
    with {:ok, raw} <- read(Path.join(t.path, @manifest), :manifest_not_found),
         {:ok, manifest} <- Manifest.parse(raw) do
      {:ok,
       %{
         media_type: manifest.media_type,
         digest: Digest.compute(raw),
         raw: raw,
         json: manifest.json
       }}
    end
  end

  @impl true
  @spec put_manifest(t(), Transport.ref(), binary(), String.t()) :: {:ok, Digest.t()}
  def put_manifest(%__MODULE__{} = t, _ref, raw, _media_type) do
    File.mkdir_p!(t.path)
    File.write!(Path.join(t.path, @manifest), raw)
    {:ok, Digest.compute(raw)}
  end

  @impl true
  @spec get_blob(t(), Digest.t()) :: {:ok, binary()} | {:error, :not_found}
  def get_blob(%__MODULE__{} = t, %Digest{} = digest), do: read(blob_path(t, digest), :not_found)

  @impl true
  @spec put_blob(t(), Digest.t(), iodata()) :: :ok | {:error, term()}
  def put_blob(%__MODULE__{} = t, %Digest{} = digest, data) do
    case Digest.verify(data, digest) do
      :ok ->
        File.mkdir_p!(t.path)
        File.write!(blob_path(t, digest), data)

      {:error, _} = error ->
        error
    end
  end

  @impl true
  @spec has_blob?(t(), Digest.t()) :: boolean()
  def has_blob?(%__MODULE__{} = t, %Digest{} = digest), do: File.exists?(blob_path(t, digest))

  @impl true
  @spec list_tags(t()) :: {:ok, [String.t()]}
  def list_tags(%__MODULE__{}), do: {:ok, []}

  @spec blob_path(t(), Digest.t()) :: Path.t()
  defp blob_path(%__MODULE__{} = t, %Digest{hex: hex}), do: Path.join(t.path, hex)

  @spec read(Path.t(), atom()) :: {:ok, binary()} | {:error, atom()}
  defp read(path, not_found_reason) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:error, not_found_reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
