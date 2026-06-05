defmodule Stevedore.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias Stevedore.Digest
  alias Stevedore.Store.Memory

  doctest Memory

  setup do
    store = start_supervised!(Memory)
    %{store: store}
  end

  test "put/get/exists?/delete round-trip", %{store: store} do
    digest = Digest.compute("blob")

    refute Memory.exists?(store, digest)
    assert Memory.put(store, digest, "blob") == :ok
    assert Memory.exists?(store, digest)
    assert Memory.get(store, digest) == {:ok, "blob"}
    assert Memory.delete(store, digest) == :ok
    refute Memory.exists?(store, digest)
  end

  test "accepts iodata and stores it as a binary", %{store: store} do
    digest = Digest.compute("ab")
    assert Memory.put(store, digest, ["a", "b"]) == :ok
    assert Memory.get(store, digest) == {:ok, "ab"}
  end

  test "rejects a digest/bytes mismatch", %{store: store} do
    assert Memory.put(store, Digest.compute("x"), "y") == {:error, :digest_mismatch}
  end

  test "get of a missing blob is not_found", %{store: store} do
    assert Memory.get(store, Digest.compute("absent")) == {:error, :not_found}
  end

  test "list returns stored digests", %{store: store} do
    a = Digest.compute("a")
    b = Digest.compute("b")
    :ok = Memory.put(store, a, "a")
    :ok = Memory.put(store, b, "b")
    assert {:ok, digests} = Memory.list(store)
    assert Enum.sort([a, b]) == Enum.sort(digests)
  end

  test "local_path is unsupported", %{store: store} do
    assert Memory.local_path(store, Digest.compute("a")) == :unsupported
  end
end
