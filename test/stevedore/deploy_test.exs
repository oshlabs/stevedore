defmodule Stevedore.DeployTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Archive, Build, Deploy, Image, MediaType}
  alias Stevedore.Transport.OCILayout

  @moduletag :tmp_dir

  defp reg(name, content),
    do: %{
      name: name,
      type: :regular,
      mode: 0o644,
      size: byte_size(content),
      linkname: nil,
      content: content
    }

  defp seed_oci(dir) do
    {:ok, image} = Build.image([Archive.write!([reg("f", "x")])], %{})
    layout = %OCILayout{path: dir}
    {:ok, %{digest: _}} = Stevedore.copy(image, {layout, "v1"})
    image
  end

  test "tree exports a static registry and returns manifest headers", %{tmp_dir: dir} do
    src = Path.join(dir, "src")
    image = seed_oci(src)
    out = Path.join(dir, "out")

    assert {:ok, headers} = Deploy.tree("oci:#{src}:v1", out, name: "lib/app")

    # The manifest is addressable by tag and by digest, with the right Content-Type + digest.
    path = "/v2/lib/app/manifests/v1"
    assert %{"Content-Type" => mt, "Docker-Content-Digest" => digest} = headers[path]
    assert mt == MediaType.oci_manifest()
    assert digest == to_string(Image.digest(image))

    assert File.regular?(Path.join([out, "v2", "lib/app", "manifests", "v1"]))
    {:ok, config_desc} = Stevedore.Manifest.config(image.manifest)

    assert File.regular?(
             Path.join([out, "v2", "lib/app", "blobs", to_string(config_desc.digest)])
           )
  end

  test "nginx_config serves the tree with the required headers", %{tmp_dir: dir} do
    src = Path.join(dir, "src")
    image = seed_oci(src)
    out = Path.join(dir, "out")
    {:ok, _} = Deploy.tree("oci:#{src}:v1", out, name: "lib/app")

    assert {:ok, config} = Deploy.nginx_config(out, port: 5005)
    assert config =~ "listen 5005;"
    assert config =~ "Docker-Distribution-Api-Version \"registry/2.0\""
    assert config =~ "location = /v2/lib/app/manifests/v1"
    assert config =~ "default_type \"#{MediaType.oci_manifest()}\""
    assert config =~ "Docker-Content-Digest \"#{to_string(Image.digest(image))}\""
    assert config =~ "blobs/(sha256:[a-f0-9]+)"
  end

  test "caddy_config serves the tree with the required headers", %{tmp_dir: dir} do
    src = Path.join(dir, "src")
    _ = seed_oci(src)
    out = Path.join(dir, "out")
    {:ok, _} = Deploy.tree("oci:#{src}:v1", out, name: "lib/app")

    assert {:ok, config} = Deploy.caddy_config(out)
    assert config =~ "path /v2/lib/app/manifests/v1"
    assert config =~ "Docker-Distribution-Api-Version"
    assert config =~ "file_server"
  end
end
