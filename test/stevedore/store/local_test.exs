defmodule Stevedore.Store.LocalTest do
  use ExUnit.Case, async: true

  alias Stevedore.Digest
  alias Stevedore.Store.Local

  @moduletag :tmp_dir

  test "put/get/exists?/delete round-trip", %{tmp_dir: root} do
    digest = Digest.compute("blob")

    refute Local.exists?(root, digest)
    assert Local.put(root, digest, "blob") == :ok
    assert Local.exists?(root, digest)
    assert Local.get(root, digest) == {:ok, "blob"}
    assert Local.delete(root, digest) == :ok
    refute Local.exists?(root, digest)
  end

  test "lays blobs out at blobs/<algo>/<hex>", %{tmp_dir: root} do
    digest = Digest.compute("blob")
    :ok = Local.put(root, digest, "blob")
    assert {:ok, path} = Local.local_path(root, digest)
    assert path == Path.join([root, "blobs", "sha256", digest.hex])
    assert File.exists?(path)
  end

  test "accepts [root: path] config too", %{tmp_dir: root} do
    digest = Digest.compute("blob")
    assert Local.put([root: root], digest, "blob") == :ok
    assert Local.get([root: root], digest) == {:ok, "blob"}
  end

  test "rejects a digest/bytes mismatch before writing", %{tmp_dir: root} do
    wrong = Digest.compute("something else")
    assert Local.put(root, wrong, "blob") == {:error, :digest_mismatch}
    refute Local.exists?(root, wrong)
  end

  test "get of a missing blob is not_found; delete is idempotent", %{tmp_dir: root} do
    digest = Digest.compute("absent")
    assert Local.get(root, digest) == {:error, :not_found}
    assert Local.delete(root, digest) == :ok
  end

  test "list returns stored digests", %{tmp_dir: root} do
    a = Digest.compute("a")
    b = Digest.compute("b")
    :ok = Local.put(root, a, "a")
    :ok = Local.put(root, b, "b")

    assert {:ok, digests} = Local.list(root)
    assert Enum.sort([a, b]) == Enum.sort(digests)
  end

  test "concurrent writers of the same blob don't corrupt it", %{tmp_dir: root} do
    digest = Digest.compute("concurrent")

    tasks = for _ <- 1..20, do: Task.async(fn -> Local.put(root, digest, "concurrent") end)
    assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
    assert Local.get(root, digest) == {:ok, "concurrent"}
  end
end
