defmodule Stevedore.ServerTest do
  # Boots a real Bandit listener; not async (binds a port, uses the default Uploads name).
  use ExUnit.Case, async: false

  alias Stevedore.{Digest, MediaType}
  alias Stevedore.Transport.OCILayout

  @moduletag :tmp_dir

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp build_image(layout, tag) do
    layer = Stevedore.Archive.gzip("server-layer")
    ld = Digest.compute(layer)
    config = ~s({"architecture":"amd64","os":"linux"})
    cd = Digest.compute(config)

    manifest =
      JSON.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => MediaType.oci_manifest(),
        "config" => %{
          "mediaType" => MediaType.oci_config(),
          "size" => byte_size(config),
          "digest" => to_string(cd)
        },
        "layers" => [
          %{
            "mediaType" => MediaType.oci_layer_gzip(),
            "size" => byte_size(layer),
            "digest" => to_string(ld)
          }
        ]
      })

    :ok = OCILayout.put_blob(layout, cd, config)
    :ok = OCILayout.put_blob(layout, ld, layer)
    {:ok, _} = OCILayout.put_manifest(layout, tag, manifest, MediaType.oci_manifest())
    %{digest: Digest.compute(manifest), raw: manifest}
  end

  test "push to and pull back from the standalone server with digests intact", %{tmp_dir: dir} do
    port = free_port()

    start_supervised!(
      {Stevedore.Server,
       store: Path.join(dir, "registry"), port: port, authorize: fn _, _, _ -> :ok end}
    )

    src = %OCILayout{path: Path.join(dir, "src")}
    img = build_image(src, "v1")

    ref = "docker://localhost:#{port}/lib/app:v1"

    # Push from the local layout into the running registry.
    assert {:ok, %{digest: pushed}} = Stevedore.copy({src, "v1"}, ref, scheme: "http")
    assert pushed == img.digest

    # Pull it back into a fresh layout; the manifest digest survives the round-trip.
    dst = %OCILayout{path: Path.join(dir, "dst")}
    assert {:ok, %{digest: pulled}} = Stevedore.copy(ref, {dst, "v1"}, scheme: "http")
    assert pulled == img.digest

    assert {:ok, fetched} = OCILayout.get_manifest(dst, "v1")
    assert fetched.raw == img.raw
  end

  test "tags list is served over HTTP after a push", %{tmp_dir: dir} do
    port = free_port()

    start_supervised!(
      {Stevedore.Server,
       store: Path.join(dir, "registry"), port: port, authorize: fn _, _, _ -> :ok end}
    )

    src = %OCILayout{path: Path.join(dir, "src")}
    build_image(src, "v1")

    {:ok, _} =
      Stevedore.copy({src, "v1"}, "docker://localhost:#{port}/lib/app:v1", scheme: "http")

    {:ok, ref} = Stevedore.Reference.parse("localhost:#{port}/lib/app")
    assert {:ok, ["v1"]} = Stevedore.list_tags(ref, scheme: "http")
  end
end
