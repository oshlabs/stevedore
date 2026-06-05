defmodule Stevedore.DigestTest do
  use ExUnit.Case, async: true

  alias Stevedore.Digest

  doctest Digest

  test "compute matches a known sha256 vector" do
    # sha256("") — the canonical empty-string digest.
    assert to_string(Digest.compute("")) ==
             "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  end

  test "compute supports sha512" do
    assert Digest.compute("", :sha512).algorithm == :sha512
    assert byte_size(Digest.compute("", :sha512).hex) == 128
  end

  test "parse round-trips to_string for both algorithms" do
    for input <- ["sha256:#{String.duplicate("a", 64)}", "sha512:#{String.duplicate("b", 128)}"] do
      assert {:ok, digest} = Digest.parse(input)
      assert to_string(digest) == input
    end
  end

  test "parse rejects unknown algorithm, bad length, and non-lowercase-hex" do
    assert {:error, {:bad_input, _}} = Digest.parse("md5:#{String.duplicate("a", 32)}")
    assert {:error, {:bad_input, _}} = Digest.parse("sha256:abc")
    assert {:error, {:bad_input, _}} = Digest.parse("sha256:#{String.duplicate("A", 64)}")
  end

  test "parse rejects path-traversal hex (no bad digest can reach the Store)" do
    assert {:error, {:bad_input, _}} = Digest.parse("sha256:../../etc/passwd")
  end

  test "verify detects mismatch" do
    assert Digest.verify("hello", Digest.compute("hello")) == :ok
    assert Digest.verify("hello", Digest.compute("world")) == {:error, :digest_mismatch}
  end
end
