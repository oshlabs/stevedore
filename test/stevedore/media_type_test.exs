defmodule Stevedore.MediaTypeTest do
  use ExUnit.Case, async: true

  alias Stevedore.MediaType

  doctest MediaType

  test "classifies OCI types" do
    assert MediaType.manifest?(MediaType.oci_manifest())
    assert MediaType.index?(MediaType.oci_index())
    assert MediaType.config?(MediaType.oci_config())
    assert MediaType.layer?(MediaType.oci_layer_gzip())
  end

  test "classifies Docker schema-2 types" do
    assert MediaType.manifest?("application/vnd.docker.distribution.manifest.v2+json")
    assert MediaType.index?("application/vnd.docker.distribution.manifest.list.v2+json")
    assert MediaType.config?("application/vnd.docker.container.image.v1+json")
    assert MediaType.layer?("application/vnd.docker.image.rootfs.diff.tar.gzip")
  end

  test "compression classifiers" do
    assert MediaType.gzip?(MediaType.oci_layer_gzip())
    refute MediaType.gzip?("application/vnd.oci.image.layer.v1.tar")
    assert MediaType.zstd?("application/vnd.oci.image.layer.v1.tar+zstd")
  end

  test "all_manifest_types covers manifests and indexes for Accept negotiation" do
    types = MediaType.all_manifest_types()
    assert MediaType.oci_manifest() in types
    assert MediaType.oci_index() in types
    assert "application/vnd.docker.distribution.manifest.v2+json" in types
  end
end
