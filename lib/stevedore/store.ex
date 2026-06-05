defmodule Stevedore.Store do
  @moduledoc """
  The content-addressed blob storage seam.

  On-disk transports (OCI layouts, the registry server, the static tree) all read and write
  blobs by digest; `Store` is the single interface they go through, so storage backends are
  interchangeable. Blobs are immutable and addressed by their `Stevedore.Digest` — there is no
  rename or mutate, only put/get/delete/exists.

  The `config` term threaded through every callback is the backend's own handle (a root path,
  an agent pid, …); each implementation defines its shape.

  Implementations: `Stevedore.Store.Local` (filesystem) and `Stevedore.Store.Memory` (in-process,
  for tests).
  """

  alias Stevedore.Digest

  @typedoc "Backend-specific handle (e.g. `{root: path}` for Local, a pid for Memory)."
  @type config :: term()

  @doc "Stores `data` under `digest`. Implementations must verify the bytes match the digest."
  @callback put(config(), Digest.t(), iodata()) :: :ok | {:error, term()}

  @doc "Fetches the blob for `digest`."
  @callback get(config(), Digest.t()) :: {:ok, binary()} | {:error, :not_found}

  @doc "Deletes the blob for `digest`. Deleting an absent blob is `:ok` (idempotent)."
  @callback delete(config(), Digest.t()) :: :ok | {:error, term()}

  @doc "Whether a blob exists for `digest`."
  @callback exists?(config(), Digest.t()) :: boolean()

  @doc "Lists the digests currently held."
  @callback list(config(), opts :: keyword()) :: {:ok, [Digest.t()]}

  @doc """
  Returns a filesystem path to the blob for zero-copy serving (`send_file`), or `:unsupported`
  for backends without a stable on-disk path.
  """
  @callback local_path(config(), Digest.t()) :: {:ok, Path.t()} | :unsupported
end
