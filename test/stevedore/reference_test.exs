defmodule Stevedore.ReferenceTest do
  use ExUnit.Case, async: true

  alias Stevedore.Reference

  doctest Reference

  test "normalizes bare Docker Hub names" do
    assert {:ok, ref} = Reference.parse("alpine")
    assert ref.registry == "registry-1.docker.io"
    assert ref.repository == "library/alpine"
    assert ref.tag == "latest"
    assert ref.digest == nil
  end

  test "keeps user repos without a library/ prefix" do
    assert {:ok, ref} = Reference.parse("user/repo:1.0")
    assert ref.registry == "registry-1.docker.io"
    assert ref.repository == "user/repo"
    assert ref.tag == "1.0"
  end

  test "treats a dotted/colon/localhost first segment as the registry" do
    assert {:ok, ref} = Reference.parse("ghcr.io/owner/app:tag")
    assert {ref.registry, ref.repository, ref.tag} == {"ghcr.io", "owner/app", "tag"}

    assert {:ok, ref} = Reference.parse("localhost:5000/app")
    assert ref.registry == "localhost:5000"
    assert ref.repository == "app"
  end

  test "parses a digest reference (no default tag)" do
    sha = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert {:ok, ref} = Reference.parse("ghcr.io/o/r@#{sha}")
    assert ref.tag == nil
    assert to_string(ref.digest) == sha
  end

  test "parses a combined tag and digest" do
    sha = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert {:ok, ref} = Reference.parse("ghcr.io/o/r:1.0@#{sha}")
    assert ref.tag == "1.0"
    assert to_string(ref.digest) == sha
  end

  test "rejects a malformed digest" do
    assert {:error, {:bad_input, _}} = Reference.parse("alpine@sha256:nothex")
  end

  test "parse |> to_string |> parse round-trips" do
    for input <- ["alpine", "alpine:3.20", "ghcr.io/owner/app:tag", "localhost:5000/app:1.0"] do
      assert {:ok, ref} = Reference.parse(input)
      assert {:ok, ^ref} = ref |> Reference.to_string() |> Reference.parse()
    end
  end
end
