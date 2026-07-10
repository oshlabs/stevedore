defmodule Stevedore.IndexTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Archive, Build, Digest, Image, Index, Manifest, MediaType}
  alias Stevedore.Transport.OCILayout

  doctest Index

  defp tiny_image(platform) do
    tar =
      Archive.write!([
        %{name: "f", type: :regular, mode: 0o644, size: 2, linkname: nil, content: "hi"}
      ])

    {:ok, image} = Build.image([tar], %{cmd: ["/f"]}, platform: platform)
    image
  end

  test "assembles a digest-correct OCI index with per-platform descriptors" do
    amd = tiny_image("linux/amd64")
    arm = tiny_image("linux/arm64")

    assert {:ok, index} = Build.index([amd, arm])
    assert index.manifest.media_type == MediaType.oci_index()
    assert Manifest.kind(index.manifest) == :index

    {:ok, [d_amd, d_arm]} = Manifest.manifests(index.manifest)
    assert d_amd.platform == %{os: "linux", architecture: "amd64", variant: nil, os_version: nil}
    assert d_arm.platform.architecture == "arm64"

    # Child descriptors are computed over the children's raw manifest bytes.
    assert d_amd.digest == Image.digest(amd)
    assert d_amd.size == byte_size(amd.manifest.raw)

    # The index digest covers the index's own raw bytes.
    assert Index.digest(index) == Digest.compute(index.manifest.raw)
  end

  test "docker format produces a manifest list" do
    {:ok, index} = Build.index([tiny_image("linux/amd64")], format: :docker)
    assert index.manifest.media_type == MediaType.docker_manifest_list()
  end

  test "rejects an image without a platform in its config" do
    tar = Archive.write!([])
    {:ok, image} = Build.image([tar], %{cmd: ["/f"]})
    # Build defaults the platform; forge a config without one.
    config = %{image.config | os: nil, architecture: nil}
    assert {:error, {:bad_input, _}} = Build.index([%{image | config: config}])
  end

  test "finds child images by manifest digest" do
    amd = tiny_image("linux/amd64")
    arm = tiny_image("linux/arm64")
    {:ok, index} = Build.index([amd, arm])

    assert {:ok, ^arm} = Index.image(index, Image.digest(arm))
    assert {:error, :not_found} = Index.image(index, Digest.compute("nope"))
  end

  @tag :tmp_dir
  test "an index is a copy source: whole index with all: true", %{tmp_dir: dir} do
    amd = tiny_image("linux/amd64")
    arm = tiny_image("linux/arm64")
    {:ok, index} = Build.index([amd, arm])

    dst = %OCILayout{path: Path.join(dir, "layout")}
    assert {:ok, %{digest: digest}} = Stevedore.copy(index, {dst, "multi"}, all: true)
    assert digest == Index.digest(index)

    # Both children round-tripped and resolve by platform from the layout.
    {:ok, fetched} = Stevedore.Transport.get_manifest(dst, "multi")
    {:ok, manifest} = Manifest.parse(fetched.raw, fetched.media_type)
    {:ok, desc} = Manifest.select(manifest, os: "linux", architecture: "arm64")
    assert desc.digest == Image.digest(arm)
    {:ok, child} = Stevedore.Transport.get_manifest(dst, desc.digest)
    assert child.raw == arm.manifest.raw
  end

  @tag :tmp_dir
  test "an index copy without all: selects one platform as a plain manifest", %{tmp_dir: dir} do
    amd = tiny_image("linux/amd64")
    arm = tiny_image("linux/arm64")
    {:ok, index} = Build.index([amd, arm])

    dst = %OCILayout{path: Path.join(dir, "layout")}

    assert {:ok, %{digest: digest}} =
             Stevedore.copy(index, {dst, "one"}, platform: "linux/arm64")

    assert digest == Image.digest(arm)
  end
end
