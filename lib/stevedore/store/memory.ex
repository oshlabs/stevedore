defmodule Stevedore.Store.Memory do
  @moduledoc """
  An in-memory `Stevedore.Store` backed by an `Agent`.

  Intended for tests and ephemeral use. The store `config` is the agent pid returned by
  `start_link/1`; the caller owns the process lifecycle (use `start_supervised!/1` in tests).
  Has no stable on-disk path, so `local_path/2` returns `:unsupported`.
  """

  @behaviour Stevedore.Store

  use Agent

  alias Stevedore.Digest

  @doc """
  Starts the store. The returned pid is the `config` passed to the other callbacks.

  ## Examples

      iex> {:ok, store} = Stevedore.Store.Memory.start_link([])
      iex> d = Stevedore.Digest.compute("blob")
      iex> Stevedore.Store.Memory.put(store, d, "blob")
      :ok
      iex> Stevedore.Store.Memory.get(store, d)
      {:ok, "blob"}
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    Agent.start_link(fn -> %{} end, opts)
  end

  @impl true
  @spec put(pid(), Digest.t(), iodata()) :: :ok | {:error, term()}
  def put(store, %Digest{} = digest, data) do
    case Digest.verify(data, digest) do
      :ok -> Agent.update(store, &Map.put(&1, digest, IO.iodata_to_binary(data)))
      {:error, _} = error -> error
    end
  end

  @impl true
  @spec get(pid(), Digest.t()) :: {:ok, binary()} | {:error, :not_found}
  def get(store, %Digest{} = digest) do
    case Agent.get(store, &Map.fetch(&1, digest)) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  @spec delete(pid(), Digest.t()) :: :ok
  def delete(store, %Digest{} = digest) do
    Agent.update(store, &Map.delete(&1, digest))
  end

  @impl true
  @spec exists?(pid(), Digest.t()) :: boolean()
  def exists?(store, %Digest{} = digest) do
    Agent.get(store, &Map.has_key?(&1, digest))
  end

  @impl true
  @spec list(pid(), keyword()) :: {:ok, [Digest.t()]}
  def list(store, _opts \\ []) do
    {:ok, Agent.get(store, &Map.keys/1)}
  end

  @impl true
  @spec local_path(pid(), Digest.t()) :: :unsupported
  def local_path(_store, %Digest{}), do: :unsupported
end
