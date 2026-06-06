defmodule Stevedore.FixturesTest do
  @moduledoc """
  Re-asserts the pinned golden constants in `Stevedore.Fixtures` through our own
  `Stevedore.Digest.compute/1`, so a drift in either the constants or our hashing is caught.
  Hermetic.
  """
  use ExUnit.Case, async: true

  alias Stevedore.{Digest, Fixtures}

  test "the OCI empty-config bytes hash to the spec digest" do
    assert to_string(Digest.compute(Fixtures.empty_config())) == Fixtures.empty_config_digest()
  end

  test "the empty blob hashes to the spec digest" do
    assert to_string(Digest.compute(Fixtures.empty_bytes())) == Fixtures.empty_bytes_digest()
  end

  describe "image/1" do
    test "builds a digest-pinned reference for a known tag" do
      assert Fixtures.image("alpine:3.20") ==
               "alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc"
    end

    test "every pinned image digest is well-formed" do
      for {tag, digest} <- Fixtures.images() do
        assert <<"sha256:", hex::binary-size(64)>> = digest, "bad digest for #{tag}"
        assert hex =~ ~r/\A[0-9a-f]{64}\z/, "non-hex digest for #{tag}"
      end
    end

    test "raises on an unpinned tag" do
      assert_raise KeyError, fn -> Fixtures.image("nginx:does-not-exist") end
    end
  end
end
