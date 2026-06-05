defmodule Stevedore.DescriptorTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Descriptor, Digest}

  doctest Descriptor

  @sha "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  test "from_json_full captures platform and optional fields" do
    json = %{
      "mediaType" => "application/vnd.oci.image.manifest.v1+json",
      "digest" => @sha,
      "size" => 7,
      "platform" => %{
        "os" => "linux",
        "architecture" => "arm64",
        "variant" => "v8",
        "os.version" => "1.0"
      },
      "annotations" => %{"k" => "v"},
      "artifactType" => "application/spdx+json"
    }

    assert {:ok, d} = Descriptor.from_json_full(json)
    assert d.platform == %{os: "linux", architecture: "arm64", variant: "v8", os_version: "1.0"}
    assert d.annotations == %{"k" => "v"}
    assert d.artifact_type == "application/spdx+json"
  end

  test "from_json rejects a missing/invalid digest" do
    assert {:error, {:bad_input, _}} = Descriptor.from_json(%{"mediaType" => "x", "size" => 1})

    assert {:error, {:bad_input, _}} =
             Descriptor.from_json(%{"mediaType" => "x", "digest" => "bad", "size" => 1})
  end

  test "to_json round-trips the platform and omits empty fields" do
    {:ok, d} =
      Descriptor.from_json_full(%{
        "mediaType" => "application/vnd.oci.image.manifest.v1+json",
        "digest" => @sha,
        "size" => 7,
        "platform" => %{"os" => "linux", "architecture" => "amd64"}
      })

    json = Descriptor.to_json(d)
    assert json["platform"] == %{"os" => "linux", "architecture" => "amd64"}
    refute Map.has_key?(json, "annotations")
    assert {:ok, ^d} = Descriptor.from_json_full(json)
  end

  test "to_json renders the digest as a string" do
    d = %Descriptor{media_type: "x", digest: Digest.compute(""), size: 0}
    assert Descriptor.to_json(d)["digest"] == @sha
  end
end
