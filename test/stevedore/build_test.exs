defmodule Stevedore.BuildTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Archive, Build, Digest, Image, Manifest, MediaType}
  alias Stevedore.Transport.OCILayout

  doctest Build

  defp reg(name, content),
    do: %{
      name: name,
      type: :regular,
      mode: 0o644,
      size: byte_size(content),
      linkname: nil,
      content: content
    }

  defp tar(entries), do: Archive.write!(entries)

  test "distinguishes diff_id (uncompressed) from the layer descriptor digest (compressed)" do
    raw = tar([reg("f", "hello")])
    {:ok, image} = Build.image([raw], %{entrypoint: ["/f"]})

    [layer] = image.layers
    [diff_id] = image.config.rootfs_diff_ids

    # The classic build bug is conflating these two: keep them straight.
    assert diff_id == Digest.compute(raw)
    assert layer.digest == Digest.compute(Archive.gzip(raw))
    refute diff_id == layer.digest
    assert layer.media_type == MediaType.oci_layer_gzip()
  end

  test ":compression :none makes diff_id equal the descriptor digest" do
    raw = tar([reg("f", "x")])
    {:ok, image} = Build.image([raw], %{}, compression: :none)
    [layer] = image.layers
    [diff_id] = image.config.rootfs_diff_ids
    assert diff_id == layer.digest
    assert layer.media_type == MediaType.oci_layer()
  end

  test ":format :docker uses Docker media types" do
    {:ok, image} = Build.image([tar([reg("f", "x")])], %{}, format: :docker)
    assert image.manifest.media_type == MediaType.docker_manifest()
    assert [%{media_type: docker_layer}] = image.layers
    assert docker_layer == MediaType.docker_layer_gzip()
  end

  @tag :tmp_dir
  test "a built image copies to an oci layout with digests intact", %{tmp_dir: dir} do
    {:ok, image} =
      Build.image([tar([reg("app", "binary")])], %{entrypoint: ["/app"], env: ["A=1"]})

    layout = %OCILayout{path: dir}

    assert {:ok, %{digest: digest}} = Stevedore.copy(image, {layout, "v1"})
    assert digest == Image.digest(image)

    assert {:ok, fetched} = OCILayout.get_manifest(layout, "v1")
    assert fetched.raw == image.manifest.raw

    {:ok, config_desc} = Manifest.config(image.manifest)
    assert OCILayout.has_blob?(layout, config_desc.digest)
    assert Enum.all?(image.layers, &OCILayout.has_blob?(layout, &1.digest))
  end

  @tag :tmp_dir
  test "from_dir is reproducible: the same tree yields the same digest", %{tmp_dir: dir} do
    tree = Path.join(dir, "rootfs")
    File.mkdir_p!(Path.join(tree, "etc"))
    File.write!(Path.join(tree, "etc/hello"), "world")
    File.write!(Path.join(tree, "run"), "#!/bin/sh\n")

    {:ok, a} = Build.from_dir(tree, %{cmd: ["/run"]})
    {:ok, b} = Build.from_dir(tree, %{cmd: ["/run"]})
    assert Image.digest(a) == Image.digest(b)
  end

  test "append adds exactly one layer and one history entry" do
    {:ok, image} = Build.image([tar([reg("a", "A")])], %{})
    assert length(image.config.history) == 1

    {:ok, image2} = Build.append(image, tar([reg("b", "B")]))
    assert length(image2.layers) == 2
    assert length(image2.config.history) == 2
    # The original layer is preserved unchanged.
    assert hd(image2.layers) == hd(image.layers)
  end
end
