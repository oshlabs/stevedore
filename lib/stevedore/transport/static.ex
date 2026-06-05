defmodule Stevedore.Transport.Static do
  @moduledoc """
  The `static:` transport — a Stevedore-native registry-v2 directory tree.

  Writes a layout a dumb web server can serve as a read-only registry:
  `v2/<name>/manifests/<tag|digest>` and `v2/<name>/blobs/<digest>`. Each manifest is written
  both by tag and by digest, with a `.mediatype` sidecar recording its `Content-Type` (which a
  static server can't infer); `Stevedore.Deploy` (Step 7) turns these into server headers.

  `:name` is the repository (e.g. `library/alpine`); `Stevedore.copy/3` fills it from the source
  when not set.

  Spec: [Docker Registry HTTP API v2](https://distribution.github.io/distribution/spec/api/).
  """

  @behaviour Stevedore.Transport

  alias Stevedore.{Digest, Manifest, Transport}

  @enforce_keys [:path]
  defstruct [:path, :name]

  @type t :: %__MODULE__{path: Path.t(), name: String.t() | nil}

  @impl true
  @spec get_manifest(t(), Transport.ref()) :: {:ok, Transport.fetched()} | {:error, term()}
  def get_manifest(%__MODULE__{} = t, ref) do
    target = target(ref)

    with {:ok, raw} <- read(manifest_path(t, target)),
         {:ok, manifest} <- Manifest.parse(raw, read_mediatype(t, target)) do
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
  def put_manifest(%__MODULE__{} = t, ref, raw, media_type) do
    digest = Digest.compute(raw)
    File.mkdir_p!(manifests_dir(t))

    # Always addressable by digest; also by tag when one is given.
    write_manifest(t, Digest.to_string(digest), raw, media_type)
    if is_binary(ref), do: write_manifest(t, ref, raw, media_type)

    {:ok, digest}
  end

  @impl true
  @spec get_blob(t(), Digest.t()) :: {:ok, binary()} | {:error, :not_found}
  def get_blob(%__MODULE__{} = t, %Digest{} = digest), do: read(blob_path(t, digest))

  @impl true
  @spec put_blob(t(), Digest.t(), iodata()) :: :ok | {:error, term()}
  def put_blob(%__MODULE__{} = t, %Digest{} = digest, data) do
    case Digest.verify(data, digest) do
      :ok ->
        File.mkdir_p!(blobs_dir(t))
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
  def list_tags(%__MODULE__{} = t) do
    tags =
      manifests_dir(t)
      |> ls()
      |> Enum.reject(&(String.contains?(&1, ":") or String.ends_with?(&1, ".mediatype")))

    {:ok, tags}
  end

  @impl true
  @spec delete(t(), Transport.ref()) :: :ok
  def delete(%__MODULE__{} = t, ref) do
    target = target(ref)
    _ = File.rm(manifest_path(t, target))
    _ = File.rm(manifest_path(t, target) <> ".mediatype")
    :ok
  end

  @doc "Deletes a blob by digest (idempotent)."
  @spec delete_blob(t(), Digest.t()) :: :ok
  def delete_blob(%__MODULE__{} = t, %Digest{} = digest) do
    _ = File.rm(blob_path(t, digest))
    :ok
  end

  @spec write_manifest(t(), String.t(), binary(), String.t()) :: :ok
  defp write_manifest(t, target, raw, media_type) do
    File.write!(manifest_path(t, target), raw)
    File.write!(manifest_path(t, target) <> ".mediatype", media_type)
  end

  @spec read_mediatype(t(), String.t()) :: String.t() | nil
  defp read_mediatype(t, target) do
    case File.read(manifest_path(t, target) <> ".mediatype") do
      {:ok, mt} -> mt
      _ -> nil
    end
  end

  @spec name(t()) :: String.t()
  defp name(%__MODULE__{name: name}) when is_binary(name), do: name

  defp name(%__MODULE__{name: nil}) do
    raise ArgumentError, "Stevedore.Transport.Static requires a :name (repository)"
  end

  @spec repo_dir(t()) :: Path.t()
  defp repo_dir(%__MODULE__{} = t), do: Path.join([t.path, "v2", name(t)])

  @spec manifests_dir(t()) :: Path.t()
  defp manifests_dir(%__MODULE__{} = t), do: Path.join(repo_dir(t), "manifests")

  @spec blobs_dir(t()) :: Path.t()
  defp blobs_dir(%__MODULE__{} = t), do: Path.join(repo_dir(t), "blobs")

  @spec manifest_path(t(), String.t()) :: Path.t()
  defp manifest_path(%__MODULE__{} = t, target), do: Path.join(manifests_dir(t), target)

  @spec blob_path(t(), Digest.t()) :: Path.t()
  defp blob_path(%__MODULE__{} = t, digest), do: Path.join(blobs_dir(t), Digest.to_string(digest))

  @spec target(Transport.ref()) :: String.t()
  defp target(%Digest{} = digest), do: Digest.to_string(digest)
  defp target(ref) when is_binary(ref), do: ref

  @spec read(Path.t()) :: {:ok, binary()} | {:error, :not_found}
  defp read(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ls(Path.t()) :: [String.t()]
  defp ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> entries
      _ -> []
    end
  end
end
