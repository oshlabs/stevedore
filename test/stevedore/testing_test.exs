defmodule Stevedore.TestingTest do
  # Boots real Bandit listeners; not async (binds ports).
  use ExUnit.Case, async: false

  alias Stevedore.Testing
  alias Stevedore.Transport.OCILayout

  @moduletag :tmp_dir

  setup %{} do
    reg = Testing.start_registry!()
    on_exit(fn -> File.rm_rf!(reg.store) end)
    %{reg: reg}
  end

  test "synthetic image round-trips through the test registry", %{reg: reg, tmp_dir: dir} do
    {:ok, image} = Testing.synthetic_image()
    ref = Testing.push!(reg, image, "lib/app:v1")
    assert ref == "#{reg.registry}/lib/app:v1"

    # Pull it back over plain HTTP; the manifest digest is unchanged.
    dst = %OCILayout{path: Path.join(dir, "dst")}
    assert {:ok, %{digest: digest}} = Stevedore.copy("docker://" <> ref, {dst, "v1"}, scheme: "http")
    assert digest == Stevedore.manifest_digest(image.manifest.raw)
  end

  test "the default synthetic image carries the tricky tar shapes" do
    {:ok, image} = Testing.synthetic_image()

    # One layer whose tar holds dirs, regular files, and an absolute symlink.
    entries = Map.new(layer_entries(image), &{&1.name, &1})

    assert %{type: :directory} = entries["etc"]
    assert %{type: :regular, content: "synthetic\n"} = entries["etc/stevedore-test"]
    assert %{type: :symlink, linkname: "/bin/busybox"} = entries["bin/sh"]
  end

  test "contents and config are overridable" do
    {:ok, image} =
      Testing.synthetic_image(
        files: %{"hello" => "world"},
        symlinks: %{},
        config: %{cmd: ["/hello"], env: ["A=1"]}
      )

    assert Enum.map(layer_entries(image), & &1.name) == ["hello"]
    assert image.config.cmd == ["/hello"]
    assert image.config.env == ["A=1"]
  end

  defp layer_entries(image) do
    [layer] = image.layers
    {:ok, entries} =
      image.blobs |> Map.fetch!(to_string(layer.digest)) |> :zlib.gunzip() |> Stevedore.Archive.read()
    entries
  end

  test "two registries run concurrently" do
    other = Testing.start_registry!()
    on_exit(fn -> File.rm_rf!(other.store) end)

    {:ok, image} = Testing.synthetic_image()
    assert Testing.push!(other, image, "x/y:z") =~ "#{other.port}/x/y:z"
    refute other.port == 0
  end
end
