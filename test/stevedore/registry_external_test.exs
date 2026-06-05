defmodule Stevedore.RegistryExternalTest do
  @moduledoc """
  Real-world conformance against public registries. Excluded by default (network); run with
  `mix test --include external`.
  """
  use ExUnit.Case, async: true

  alias Stevedore.{Config, Digest, Manifest, Reference, Registry}

  @moduletag :external

  for {name, input} <- [
        docker_hub: "alpine:3.20",
        ghcr: "ghcr.io/astral-sh/uv:latest"
      ] do
    test "pulls #{name} with digest-stable manifest and verified blobs" do
      {:ok, ref} = Reference.parse(unquote(input))

      assert {:ok, fetched} = Registry.manifest(ref)
      # The registry's Docker-Content-Digest matches a digest over the raw bytes.
      assert fetched.digest == Digest.compute(fetched.raw)

      {:ok, manifest} = Manifest.parse(fetched.raw, fetched.media_type)

      image =
        case Manifest.kind(manifest) do
          :manifest ->
            manifest

          :index ->
            {:ok, desc} = Manifest.select(manifest)
            image_ref = %{ref | tag: nil, digest: desc.digest}
            {:ok, f} = Registry.manifest(image_ref)
            {:ok, m} = Manifest.parse(f.raw, f.media_type)
            m
        end

      {:ok, config_desc} = Manifest.config(image)
      image_ref = %{ref | tag: nil, digest: fetched.digest}
      assert {:ok, config_bytes} = Registry.blob(image_ref, config_desc.digest)
      # blob/3 already verifies the digest; confirm it parses as a config.
      assert {:ok, %Config{}} = Config.parse(config_bytes)
    end
  end

  test "selects the host platform from a multi-arch index" do
    {:ok, ref} = Reference.parse("alpine:3.20")
    {:ok, fetched} = Registry.manifest(ref)
    {:ok, manifest} = Manifest.parse(fetched.raw, fetched.media_type)

    if Manifest.kind(manifest) == :index do
      assert {:ok, desc} = Manifest.select(manifest)
      assert desc.platform.os == "linux"
    end
  end
end
