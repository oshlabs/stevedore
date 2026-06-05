defmodule Stevedore.ManifestTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Manifest, MediaType}

  doctest Manifest

  @sha "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @image ~s({
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.manifest.v1+json",
    "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "size": 7, "digest": "#{@sha}"},
    "layers": [
      {"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "size": 100, "digest": "#{@sha}"},
      {"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "size": 200, "digest": "#{@sha}"}
    ]
  })

  @index ~s({
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.index.v1+json",
    "manifests": [
      {"mediaType": "application/vnd.oci.image.manifest.v1+json", "size": 1, "digest": "#{@sha}",
       "platform": {"os": "linux", "architecture": "amd64"}},
      {"mediaType": "application/vnd.oci.image.manifest.v1+json", "size": 1, "digest": "#{@sha}",
       "platform": {"os": "linux", "architecture": "arm64", "variant": "v8"}}
    ]
  })

  test "kind is detected from the media type" do
    assert {:ok, m} = Manifest.parse(@image)
    assert Manifest.kind(m) == :manifest
    assert {:ok, i} = Manifest.parse(@index)
    assert Manifest.kind(i) == :index
  end

  test "kind falls back to structure when mediaType is absent" do
    assert {:ok, m} = Manifest.parse(~s({"config": {}, "layers": []}))
    assert Manifest.kind(m) == :manifest
    assert {:ok, i} = Manifest.parse(~s({"manifests": []}))
    assert Manifest.kind(i) == :index
  end

  test "content_type argument wins over the JSON mediaType" do
    {:ok, m} = Manifest.parse(~s({"manifests": []}), MediaType.oci_index())
    assert m.media_type == MediaType.oci_index()
  end

  test "config and layers extract descriptors from an image manifest" do
    {:ok, m} = Manifest.parse(@image)
    assert {:ok, config} = Manifest.config(m)
    assert config.media_type == "application/vnd.oci.image.config.v1+json"
    assert {:ok, [l1, l2]} = Manifest.layers(m)
    assert {l1.size, l2.size} == {100, 200}
    assert {:error, :not_an_index} = Manifest.manifests(m)
  end

  test "manifests lists index entries; config/layers reject an index" do
    {:ok, i} = Manifest.parse(@index)
    assert {:ok, [_, _]} = Manifest.manifests(i)
    assert {:error, :not_a_manifest} = Manifest.config(i)
    assert {:error, :not_a_manifest} = Manifest.layers(i)
  end

  test "select matches os/architecture and an optional variant" do
    {:ok, i} = Manifest.parse(@index)
    assert {:ok, d} = Manifest.select(i, os: "linux", architecture: "amd64")
    assert d.platform.architecture == "amd64"

    assert {:ok, d} = Manifest.select(i, os: "linux", architecture: "arm64", variant: "v8")
    assert d.platform.variant == "v8"

    assert {:error, :no_match} = Manifest.select(i, os: "linux", architecture: "ppc64le")

    assert {:error, :no_match} =
             Manifest.select(i, os: "linux", architecture: "arm64", variant: "v7")
  end

  test "select on a single manifest is not_an_index" do
    {:ok, m} = Manifest.parse(@image)
    assert {:error, :not_an_index} = Manifest.select(m, os: "linux", architecture: "amd64")
  end

  test "digest is computed over the raw bytes" do
    {:ok, m} = Manifest.parse(@image)
    assert m.digest == Stevedore.Digest.compute(@image)
  end

  test "host_platform returns linux/amd64-style keywords" do
    assert [os: os, architecture: arch] = Manifest.host_platform()
    assert is_binary(os) and is_binary(arch)
  end
end
