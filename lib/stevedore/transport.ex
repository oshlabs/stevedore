defmodule Stevedore.Transport do
  @moduledoc """
  The seam describing **where images live**, behind one uniform interface.

  A transport instance is a struct (carrying its own config — a registry repository, a layout
  path, a `Store`, …) whose module implements this behaviour. The functions in this module
  dispatch to that module based on the struct, so callers (notably `Stevedore.copy/3`) work
  against any transport interchangeably:

      Stevedore.Transport.get_manifest(transport, "3.20")

  Implementations: `Stevedore.Transport.Registry` (`docker://`), `Transport.OCILayout` (`oci:`),
  `Transport.Dir` (`dir:`), `Transport.Archive` (`docker-archive:`), and `Transport.Static`.

  Spec: [containers-transports(5)](https://github.com/containers/image/blob/main/docs/containers-transports.5.md).
  """

  alias Stevedore.Digest

  @type t :: struct()
  @type ref :: String.t() | Digest.t() | nil
  @type fetched :: %{media_type: String.t(), digest: Digest.t(), raw: binary(), json: map()}

  @doc "Fetch a manifest (or index) by tag or digest."
  @callback get_manifest(t(), ref()) :: {:ok, fetched()} | {:error, term()}

  @doc "Store raw manifest bytes, optionally tagged as `ref`. Returns the manifest digest."
  @callback put_manifest(t(), ref(), raw :: binary(), media_type :: String.t()) ::
              {:ok, Digest.t()} | {:error, term()}

  @doc "Fetch a blob by digest."
  @callback get_blob(t(), Digest.t()) :: {:ok, binary()} | {:error, term()}

  @doc "Store a blob (the implementation verifies it against `digest`)."
  @callback put_blob(t(), Digest.t(), iodata()) :: :ok | {:error, term()}

  @doc "Whether the blob is already present (lets `copy` skip it)."
  @callback has_blob?(t(), Digest.t()) :: boolean()

  @doc "List tags held by this transport."
  @callback list_tags(t()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "Delete a manifest by tag or digest."
  @callback delete(t(), ref()) :: :ok | {:error, term()}

  @doc "Flush any buffered state (e.g. emit a tar). Called once at the end of a copy."
  @callback finalize(t()) :: :ok | {:error, term()}

  @optional_callbacks [finalize: 1, list_tags: 1, delete: 2]

  @doc "Dispatch `get_manifest/2` to `transport`'s implementation."
  @spec get_manifest(t(), ref()) :: {:ok, fetched()} | {:error, term()}
  def get_manifest(%mod{} = t, ref), do: mod.get_manifest(t, ref)

  @doc "Dispatch `put_manifest/4`."
  @spec put_manifest(t(), ref(), binary(), String.t()) :: {:ok, Digest.t()} | {:error, term()}
  def put_manifest(%mod{} = t, ref, raw, media_type),
    do: mod.put_manifest(t, ref, raw, media_type)

  @doc "Dispatch `get_blob/2`."
  @spec get_blob(t(), Digest.t()) :: {:ok, binary()} | {:error, term()}
  def get_blob(%mod{} = t, digest), do: mod.get_blob(t, digest)

  @doc "Dispatch `put_blob/3`."
  @spec put_blob(t(), Digest.t(), iodata()) :: :ok | {:error, term()}
  def put_blob(%mod{} = t, digest, data), do: mod.put_blob(t, digest, data)

  @doc "Dispatch `has_blob?/2`."
  @spec has_blob?(t(), Digest.t()) :: boolean()
  def has_blob?(%mod{} = t, digest), do: mod.has_blob?(t, digest)

  @doc "Dispatch `list_tags/1`."
  @spec list_tags(t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_tags(%mod{} = t), do: mod.list_tags(t)

  @doc "Dispatch `delete/2`."
  @spec delete(t(), ref()) :: :ok | {:error, term()}
  def delete(%mod{} = t, ref), do: mod.delete(t, ref)

  @doc "Dispatch `finalize/1`, or `:ok` for transports that don't define it."
  @spec finalize(t()) :: :ok | {:error, term()}
  def finalize(%mod{} = t) do
    if function_exported?(mod, :finalize, 1), do: mod.finalize(t), else: :ok
  end
end
