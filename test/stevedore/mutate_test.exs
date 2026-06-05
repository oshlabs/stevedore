defmodule Stevedore.MutateTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Archive, Build, Digest, Image, Manifest, Mutate}

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

  defp build(layers, config \\ %{}), do: Build.image(layers, config) |> elem(1)

  test "config rewrite changes the config digest but leaves layers untouched" do
    image = build([tar([reg("f", "x")])], %{entrypoint: ["/old"]})
    mutated = Mutate.config(image, %{entrypoint: ["/new"], env: ["DEBUG=0"]})

    assert mutated.config.entrypoint == ["/new"]
    assert mutated.config.env == ["DEBUG=0"]
    assert mutated.layers == image.layers
    refute Image.digest(mutated) == Image.digest(image)

    {:ok, c1} = Manifest.config(image.manifest)
    {:ok, c2} = Manifest.config(mutated.manifest)
    refute c1.digest == c2.digest
  end

  test "config accepts a function over the Config struct" do
    image = build([tar([reg("f", "x")])], %{cmd: ["/a"]})
    mutated = Mutate.config(image, fn config -> %{config | cmd: ["/b"]} end)
    assert mutated.config.cmd == ["/b"]
  end

  test "annotations are merged into the manifest, leaving config and layers untouched" do
    image = build([tar([reg("f", "x")])])
    mutated = Mutate.annotations(image, %{"org.opencontainers.image.source" => "https://x"})

    assert mutated.manifest.json["annotations"] == %{
             "org.opencontainers.image.source" => "https://x"
           }

    assert mutated.config == image.config
    assert mutated.layers == image.layers
    refute Image.digest(mutated) == Image.digest(image)
  end

  test "retag sets the tag used by a later copy" do
    image = build([tar([reg("f", "x")])])
    assert Mutate.retag(image, "1.0.1").tag == "1.0.1"
  end

  test "rebase swaps the base layers and round-trips back to the original" do
    base_layer = tar([reg("base", "B")])
    new_base_layer = tar([reg("newbase", "N")])
    app_layer = tar([reg("app", "A")])

    base = build([base_layer])
    new_base = build([new_base_layer])
    app = build([base_layer, app_layer], %{entrypoint: ["/app"]})

    assert {:ok, rebased} = Mutate.rebase(app, base, new_base)
    assert diff_ids(rebased) == diff_ids(new_base) ++ [List.last(diff_ids(app))]

    # Rebasing back recovers the original image exactly.
    assert {:ok, back} = Mutate.rebase(rebased, new_base, base)
    assert Image.digest(back) == Image.digest(app)
  end

  test "rebase rejects an image that doesn't start with the old base" do
    app = build([tar([reg("a", "A")])])
    wrong_base = build([tar([reg("z", "Z")])])
    other = build([tar([reg("b", "B")])])
    assert {:error, :base_mismatch} = Mutate.rebase(app, wrong_base, other)
  end

  test "flatten merges layers and applies whiteouts" do
    layer1 = tar([reg("a", "A"), reg("b", "B")])
    layer2 = tar([reg(".wh.a", ""), reg("c", "C")])
    image = build([layer1, layer2])

    assert {:ok, flat} = Mutate.flatten(image)
    assert length(flat.layers) == 1

    [layer] = flat.layers
    {:ok, raw} = Archive.gunzip(Map.fetch!(flat.blobs, to_string(layer.digest)))
    {:ok, entries} = Archive.read(raw)
    names = entries |> Enum.map(& &1.name) |> Enum.sort()

    # "a" was whited out; "b" and "c" remain.
    assert names == ["b", "c"]
    assert [single_diff] = flat.config.rootfs_diff_ids
    assert single_diff == Digest.compute(raw)
  end

  defp diff_ids(image), do: Enum.map(image.config.rootfs_diff_ids, &to_string/1)
end
