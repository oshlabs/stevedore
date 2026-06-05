defmodule Stevedore.Transport.Registry do
  @moduledoc """
  The `docker://` transport: a remote registry, behind the `Stevedore.Transport` behaviour.

  A thin wrapper over `Stevedore.Registry` (which owns the HTTP + auth). Carries the target
  `registry`/`repository` and the per-call `opts` (`:creds`, `:scheme`, …). Supports the push
  path (manifest/blob upload) and cross-repo blob mount.
  """

  @behaviour Stevedore.Transport

  alias Stevedore.{Digest, Reference, Registry, Transport}

  @enforce_keys [:registry, :repository]
  defstruct [:registry, :repository, opts: []]

  @type t :: %__MODULE__{registry: String.t(), repository: String.t(), opts: keyword()}

  @impl true
  @spec get_manifest(t(), Transport.ref()) :: {:ok, Transport.fetched()} | {:error, term()}
  def get_manifest(%__MODULE__{} = t, ref), do: Registry.manifest(reference(t, ref), t.opts)

  @impl true
  @spec put_manifest(t(), Transport.ref(), binary(), String.t()) ::
          {:ok, Digest.t()} | {:error, term()}
  def put_manifest(%__MODULE__{} = t, ref, raw, media_type) do
    # Tag or digest as given; fall back to the content digest so there is always a target.
    target_ref = ref || Digest.compute(raw)
    Registry.put_manifest(reference(t, target_ref), raw, media_type, t.opts)
  end

  @impl true
  @spec get_blob(t(), Digest.t()) :: {:ok, binary()} | {:error, term()}
  def get_blob(%__MODULE__{} = t, %Digest{} = digest),
    do: Registry.blob(reference(t, nil), digest, t.opts)

  @impl true
  @spec put_blob(t(), Digest.t(), iodata()) :: :ok | {:error, term()}
  def put_blob(%__MODULE__{} = t, %Digest{} = digest, data),
    do: Registry.put_blob(reference(t, nil), digest, data, t.opts)

  @impl true
  @spec has_blob?(t(), Digest.t()) :: boolean()
  def has_blob?(%__MODULE__{} = t, %Digest{} = digest),
    do: Registry.has_blob?(reference(t, nil), digest, t.opts)

  @impl true
  @spec list_tags(t()) :: {:ok, [String.t()]} | {:error, term()}
  def list_tags(%__MODULE__{} = t), do: Registry.list_tags(reference(t, nil), t.opts)

  @impl true
  @spec delete(t(), Transport.ref()) :: :ok | {:error, term()}
  def delete(%__MODULE__{} = t, ref),
    do: Registry.delete_manifest(reference(t, nil), target(ref), t.opts)

  @doc """
  Attempts a cross-repo mount of `digest` into this transport's repository from `from_repo`.
  Returns `:not_mounted` when the registry declines.
  """
  @spec mount(t(), Digest.t(), String.t()) :: :ok | :not_mounted
  def mount(%__MODULE__{} = t, %Digest{} = digest, from_repo) do
    Registry.mount_blob(reference(t, nil), digest, from_repo, t.opts)
  end

  @spec reference(t(), Transport.ref()) :: Reference.t()
  defp reference(%__MODULE__{} = t, %Digest{} = digest) do
    %Reference{registry: t.registry, repository: t.repository, digest: digest}
  end

  defp reference(%__MODULE__{} = t, ref) when is_binary(ref) do
    %Reference{registry: t.registry, repository: t.repository, tag: ref}
  end

  defp reference(%__MODULE__{} = t, nil) do
    %Reference{registry: t.registry, repository: t.repository}
  end

  @spec target(Transport.ref()) :: String.t()
  defp target(%Digest{} = digest), do: Digest.to_string(digest)
  defp target(ref) when is_binary(ref), do: ref
end
