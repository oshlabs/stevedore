defmodule Stevedore.SchemaValidityTest do
  @moduledoc """
  Format validity (Step 9B, Strategy 4): every JSON document Stevedore emits — image **manifest**,
  **image index**, **config**, and **descriptor** — is validated against the authoritative OCI
  image-spec JSON Schemas, not against our own parsers. This catches required-field, type, and
  constant violations (e.g. `schemaVersion != 2`, a missing `digest`) that a lenient round-trip
  through our own decoders would happily accept.

  Hermetic and offline — runs inside the default `mix test` (the `fast` CI job), no tag needed:

      mix test test/stevedore/schema_validity_test.exs

  Schemas are vendored under `test/support/schema/` (pinned to image-spec v1.1.1 — see that dir's
  `SOURCE`) and applied via `Stevedore.SchemaValidator`. Spec references:

    * manifest — <https://github.com/opencontainers/image-spec/blob/v1.1.1/manifest.md>
    * image-index — <https://github.com/opencontainers/image-spec/blob/v1.1.1/image-index.md>
    * config — <https://github.com/opencontainers/image-spec/blob/v1.1.1/config.md>
    * descriptor — <https://github.com/opencontainers/image-spec/blob/v1.1.1/descriptor.md>
  """

  use ExUnit.Case, async: true

  alias Stevedore.{Archive, Build, Descriptor, Digest, Image, Manifest, MediaType, Referrers}
  alias Stevedore.SchemaValidator, as: Schema
  alias Stevedore.Transport.Static

  @manifest_schema "image-manifest-schema.json"
  @index_schema "image-index-schema.json"
  @config_schema "config-schema.json"
  @descriptor_schema "content-descriptor.json"

  defp reg(name, content),
    do: %{
      name: name,
      type: :regular,
      mode: 0o644,
      size: byte_size(content),
      linkname: nil,
      content: content
    }

  # A real, deterministic two-layer image with a populated runtime config.
  defp built_image do
    layers = [Archive.write!([reg("a", "alpha")]), Archive.write!([reg("b", "beta")])]
    {:ok, image} = Build.image(layers, %{entrypoint: ["/a"], cmd: ["x"], env: ["PATH=/bin"]})
    image
  end

  describe "image manifest" do
    test "a built image's manifest validates against image-manifest-schema" do
      assert :ok = Schema.validate(@manifest_schema, built_image().manifest.json)
    end

    test "a manifest carrying annotations validates" do
      image = built_image()

      {:ok, annotated} =
        Image.assemble(image.config.json, Image.layers(image),
          annotations: %{"org.opencontainers.image.title" => "demo"}
        )

      assert %{"annotations" => %{"org.opencontainers.image.title" => "demo"}} =
               annotated.manifest.json

      assert :ok = Schema.validate(@manifest_schema, annotated.manifest.json)
    end

    @tag :tmp_dir
    test "an OCI 1.1 artifact manifest (empty config, artifactType, subject) validates", %{
      tmp_dir: dir
    } do
      # `Referrers.attach/4` emits an artifact manifest: an OCI empty-config descriptor, the
      # artifact as a single layer, an `artifactType`, and a `subject` pointing at the image.
      # image-spec manifest.md "Guidelines for Artifact Usage".
      static = %Static{path: dir, name: "lib/app"}
      image = built_image()
      {:ok, _} = Stevedore.copy(image, {static, "v1"})

      {:ok, artifact_digest} =
        Referrers.attach(static, Image.digest(image), %{
          media_type: "application/spdx+json",
          data: ~s({"spdxVersion":"SPDX-2.3"}),
          artifact_type: "application/spdx+json"
        })

      {:ok, artifact} = Static.get_manifest(static, to_string(artifact_digest))

      assert Map.has_key?(artifact.json, "subject")
      assert artifact.json["artifactType"] == "application/spdx+json"
      assert artifact.json["config"]["mediaType"] == MediaType.oci_config()
      assert :ok = Schema.validate(@manifest_schema, artifact.json)
    end

    test "a manifest missing the required layers field is rejected (negative control)" do
      assert {:error, errors} =
               Schema.validate(@manifest_schema, %{
                 "schemaVersion" => 2,
                 "mediaType" => MediaType.oci_manifest(),
                 "config" => Descriptor.to_json(empty_config_descriptor())
               })

      assert Enum.any?(errors, fn {msg, _path} -> msg =~ "layers" end)
    end
  end

  describe "image index" do
    @tag :tmp_dir
    test "an emitted referrers index validates against image-index-schema", %{tmp_dir: dir} do
      static = %Static{path: dir, name: "lib/app"}
      image = built_image()
      {:ok, _} = Stevedore.copy(image, {static, "v1"})
      subject = Image.digest(image)

      {:ok, _} =
        Referrers.attach(static, subject, %{
          media_type: "application/spdx+json",
          data: ~s({"spdxVersion":"SPDX-2.3"}),
          artifact_type: "application/spdx+json"
        })

      {:ok, index} = Referrers.list(static, subject)
      assert {:ok, [_ | _]} = Manifest.manifests(index)
      assert :ok = Schema.validate(@index_schema, index.json)
    end

    @tag :tmp_dir
    test "an empty referrers index validates", %{tmp_dir: dir} do
      static = %Static{path: dir, name: "lib/app"}
      image = built_image()
      {:ok, _} = Stevedore.copy(image, {static, "v1"})

      {:ok, index} = Referrers.list(static, Digest.compute("no-such-subject"))
      assert {:ok, []} = Manifest.manifests(index)
      assert :ok = Schema.validate(@index_schema, index.json)
    end

    test "a multi-arch index with platform entries and a subject validates" do
      # image-index.md: each entry is a descriptor with a `platform` object; an index may itself
      # carry a `subject` (OCI 1.1 referrers). Built from real per-platform manifests so the
      # descriptors (digest/size/platform), serialized by Stevedore.Descriptor, are genuine.
      {:ok, amd} =
        Build.image([Archive.write!([reg("a", "alpha")])], %{}, platform: "linux/amd64")

      {:ok, arm} =
        Build.image([Archive.write!([reg("a", "alpha")])], %{}, platform: "linux/arm64")

      subject = built_image()

      index_json = %{
        "schemaVersion" => 2,
        "mediaType" => MediaType.oci_index(),
        "manifests" => [
          Descriptor.to_json(platform_descriptor(amd, "linux", "amd64")),
          Descriptor.to_json(platform_descriptor(arm, "linux", "arm64"))
        ],
        "subject" => Descriptor.to_json(manifest_descriptor(subject))
      }

      {:ok, index} = Manifest.parse(JSON.encode!(index_json), MediaType.oci_index())
      assert :ok = Schema.validate(@index_schema, index.json)
    end
  end

  describe "image config" do
    test "a built image's config (env/entrypoint/cmd, history, multiple diff_ids) validates" do
      config = built_image().config.json

      assert length(config["rootfs"]["diff_ids"]) == 2
      assert config["config"]["Env"] == ["PATH=/bin"]
      assert is_list(config["history"])
      assert :ok = Schema.validate(@config_schema, config)
    end

    test "a config missing the required rootfs field is rejected (negative control)" do
      assert {:error, errors} =
               Schema.validate(@config_schema, %{"architecture" => "amd64", "os" => "linux"})

      assert Enum.any?(errors, fn {msg, _path} -> msg =~ "rootfs" end)
    end
  end

  describe "descriptor" do
    test "a plain layer descriptor validates against content-descriptor" do
      descriptor = %Descriptor{
        media_type: MediaType.oci_layer_gzip(),
        digest: Digest.compute("layer"),
        size: 5
      }

      assert :ok = Schema.validate(@descriptor_schema, Descriptor.to_json(descriptor))
    end

    test "a descriptor with platform, annotations and urls validates" do
      descriptor = %Descriptor{
        media_type: MediaType.oci_manifest(),
        digest: Digest.compute("manifest"),
        size: 8,
        platform: %{os: "linux", architecture: "arm64", variant: "v8", os_version: nil},
        annotations: %{"org.opencontainers.image.title" => "demo"},
        urls: ["https://example.test/blob"]
      }

      assert :ok = Schema.validate(@descriptor_schema, Descriptor.to_json(descriptor))
    end

    test "a descriptor missing the required mediaType is rejected (negative control)" do
      assert {:error, errors} =
               Schema.validate(@descriptor_schema, %{
                 "digest" => to_string(Digest.compute("x")),
                 "size" => 1
               })

      assert Enum.any?(errors, fn {msg, _path} -> msg =~ "mediaType" end)
    end
  end

  defp empty_config_descriptor do
    %Descriptor{
      media_type: MediaType.oci_config(),
      digest: Digest.compute("{}"),
      size: 2
    }
  end

  defp manifest_descriptor(image) do
    %Descriptor{
      media_type: image.manifest.media_type,
      digest: image.manifest.digest,
      size: byte_size(image.manifest.raw)
    }
  end

  defp platform_descriptor(image, os, arch) do
    %{
      manifest_descriptor(image)
      | platform: %{os: os, architecture: arch, variant: nil, os_version: nil}
    }
  end
end
