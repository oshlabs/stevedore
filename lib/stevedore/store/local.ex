defmodule Stevedore.Store.Local do
  @moduledoc """
  A filesystem-backed `Stevedore.Store`.

  Blobs are laid out as `<root>/blobs/<algorithm>/<hex>`, matching the OCI image-layout blob
  convention. Writes are **atomic** (temp file + `File.rename/2`) and **digest-verified** (the
  bytes must hash to the digest before the blob is committed). The on-disk path is derived only
  from a validated `Stevedore.Digest`, never from caller-supplied strings, so there is no
  path-traversal surface.

  The store `config` is the root directory, given as a path string or `[root: path]`.

  Spec: [OCI image-layout](https://github.com/opencontainers/image-spec/blob/main/image-layout.md).
  """

  @behaviour Stevedore.Store

  alias Stevedore.Digest

  @impl true
  @spec put(Stevedore.Store.config(), Digest.t(), iodata()) :: :ok | {:error, term()}
  def put(config, %Digest{} = digest, data) do
    case Digest.verify(data, digest) do
      :ok -> write_atomic(path(config, digest), data)
      {:error, _} = error -> error
    end
  end

  @impl true
  @spec get(Stevedore.Store.config(), Digest.t()) :: {:ok, binary()} | {:error, :not_found}
  def get(config, %Digest{} = digest) do
    case File.read(path(config, digest)) do
      {:ok, data} ->
        {:ok, data}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read blob", path: path(config, digest)
    end
  end

  @impl true
  @spec delete(Stevedore.Store.config(), Digest.t()) :: :ok | {:error, term()}
  def delete(config, %Digest{} = digest) do
    case File.rm(path(config, digest)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec exists?(Stevedore.Store.config(), Digest.t()) :: boolean()
  def exists?(config, %Digest{} = digest), do: File.exists?(path(config, digest))

  @impl true
  @spec list(Stevedore.Store.config(), keyword()) :: {:ok, [Digest.t()]}
  def list(config, _opts \\ []) do
    digests =
      config
      |> blobs_dir()
      |> Path.join("*/*")
      |> Path.wildcard()
      |> Enum.flat_map(&digest_from_path/1)

    {:ok, digests}
  end

  @impl true
  @spec local_path(Stevedore.Store.config(), Digest.t()) :: {:ok, Path.t()}
  def local_path(config, %Digest{} = digest), do: {:ok, path(config, digest)}

  @spec write_atomic(Path.t(), iodata()) :: :ok | {:error, term()}
  defp write_atomic(final, data) do
    dir = Path.dirname(final)
    tmp = Path.join(dir, ".tmp-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, data),
         :ok <- File.rename(tmp, final) do
      :ok
    else
      {:error, _} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  @spec path(Stevedore.Store.config(), Digest.t()) :: Path.t()
  defp path(config, digest), do: Path.join(blobs_dir(config), Digest.to_path(digest))

  @spec blobs_dir(Stevedore.Store.config()) :: Path.t()
  defp blobs_dir(config), do: Path.join(root(config), "blobs")

  @spec root(Stevedore.Store.config()) :: binary()
  defp root(config) when is_binary(config), do: config
  defp root(config) when is_list(config), do: Keyword.fetch!(config, :root)

  # Reconstruct a digest from a "<root>/blobs/<algo>/<hex>" path; skip unknown algorithms
  # (never String.to_atom an on-disk name).
  @spec digest_from_path(Path.t()) :: [Digest.t()]
  defp digest_from_path(path) do
    algo = path |> Path.dirname() |> Path.basename()
    hex = Path.basename(path)

    case algo do
      "sha256" -> [%Digest{algorithm: :sha256, hex: hex}]
      "sha512" -> [%Digest{algorithm: :sha512, hex: hex}]
      _ -> []
    end
  end
end
