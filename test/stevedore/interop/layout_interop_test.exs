defmodule Stevedore.Interop.LayoutInteropTest do
  @moduledoc """
  Strategy 3 (part 1 of 4) — **on-disk transport interop**. Prove the layouts/archives Stevedore
  *writes* are readable by other tools, and that Stevedore can *read* what they write, crossing the
  tool boundary in **both** directions so a re-serialization bug shows up as a digest mismatch the
  moment a different tool touches our bytes.

  Transports under test (`lib/stevedore/transport/parse.ex`): `oci:` (OCI image layout), `oci-archive:`
  (that layout as a tar), `docker-archive:` (a `docker save` tarball), and `dir:` (skopeo's flat
  dir). Oracles: `skopeo` (reads/writes all four natively), `regctl` (OCI layout), `docker` (loads
  the docker-archive).

  ## Why hermetic, not network-pulled

  Sources are **built locally** (`Stevedore.Build`, real tar layers so `docker load` can extract
  them) rather than pulled from a registry. That keeps this suite offline and deterministic while
  staying genuinely *asymmetric*: the oracle re-serializes the bytes, so when Stevedore reads them
  back (or the oracle reads ours) any encoding drift is caught. Digest-pinned *public* round-trips
  are covered by the `:external` step (9D); here the boundary that matters is tool↔tool on disk.

  ## What we assert

    * **Digest stability across the boundary** — the digest-preserving guarantee. For content-
      addressable layouts (`oci:`, `oci-archive:`, `dir:`) the *manifest* digest is byte-stable end
      to end. `docker-archive:` is a lossy format (Docker schema2, no embedded OCI manifest), so the
      stable invariant there is the **config** digest (the Docker image id) — asserted instead.
    * **Layout correctness** — `oci-layout` marker + `index.json` + `blobs/sha256/<hex>` per the
      image-layout spec.
    * **Media-type fidelity** — Docker v2s2 media types survive a round-trip without being coerced
      to OCI.
    * **Compression fidelity** — gzip (and zstd, when `:ezstd` is built) layers round-trip.

  Tag: `:interop`. Cases skip cleanly when their oracle is absent (`Stevedore.TestTools`). Run:

      mix test --include interop test/stevedore/interop/layout_interop_test.exs

  Specs / tool docs:
    * image-layout — <https://github.com/opencontainers/image-spec/blob/main/image-layout.md>
    * containers-transports(5) (skopeo `oci:`/`oci-archive:`/`docker-archive:`/`dir:`) —
      <https://github.com/containers/image/blob/main/docs/containers-transports.5.md>
    * `regctl` ocidir — <https://github.com/regclient/regclient/blob/main/docs/regctl.md>
    * `docker load` — <https://docs.docker.com/reference/cli/docker/image/load/>
  """
  use ExUnit.Case, async: false

  import Stevedore.TestTools, only: [tool_test: 3, find: 1]

  alias Stevedore.{Build, Digest, Image, Manifest, MediaType, Transport}

  @moduletag :interop

  describe "oci: (OCI image layout)" do
    tool_test "skopeo reads the layout Stevedore wrote, agreeing on the manifest digest",
              ["skopeo"] do
      image = loadable_image("oci-skopeo")
      dir = tmp("oci")
      assert {:ok, %{digest: digest}} = Stevedore.copy(image, "oci:#{dir}:v1")

      # The whole point: a *different* tool, reading our bytes, computes the same manifest digest.
      assert Digest.compute(skopeo_raw("oci:#{dir}:v1")) == digest

      # image-layout spec: marker file, index.json pointing at the manifest, content-addressed blob.
      assert File.read!(Path.join(dir, "oci-layout")) =~ ~s("imageLayoutVersion":"1.0.0")
      index = JSON.decode!(File.read!(Path.join(dir, "index.json")))
      assert [%{"digest" => manifest_digest}] = index["manifests"]
      assert manifest_digest == Digest.to_string(digest)
      assert File.exists?(Path.join([dir, "blobs", "sha256", digest.hex]))
    end

    tool_test "regctl reads the layout Stevedore wrote, agreeing on the manifest digest",
              ["regctl"] do
      image = loadable_image("oci-regctl")
      dir = tmp("oci")
      assert {:ok, %{digest: digest}} = Stevedore.copy(image, "oci:#{dir}:v1")

      # regctl addresses an on-disk layout as ocidir://<path>:<tag>.
      reported =
        run!("regctl", [
          "manifest",
          "get",
          "ocidir://#{dir}:v1",
          "--format",
          "{{.GetDescriptor.Digest}}"
        ])

      assert String.trim(reported) == Digest.to_string(digest)
    end

    tool_test "Stevedore reads back a layout skopeo re-serialized, preserving the manifest digest",
              ["skopeo"] do
      image = loadable_image("oci-reverse")
      ours = tmp("oci")
      theirs = tmp("oci")
      assert {:ok, %{digest: digest}} = Stevedore.copy(image, "oci:#{ours}:v1")

      # skopeo re-serializes our layout into a fresh one; Stevedore must read *their* bytes back at
      # the identical digest.
      run!("skopeo", ["copy", "oci:#{ours}:v1", "oci:#{theirs}:v1"])

      final = tmp("oci")

      assert {:ok, %{digest: round_tripped}} =
               Stevedore.copy("oci:#{theirs}:v1", "oci:#{final}:v1")

      assert round_tripped == digest
    end
  end

  describe "oci-archive: (OCI layout as a tar)" do
    tool_test "skopeo reads the archive Stevedore wrote, agreeing on the manifest digest",
              ["skopeo"] do
      image = loadable_image("ociarchive-skopeo")
      tar = tmp("oci") <> ".tar"
      assert {:ok, %{digest: digest}} = Stevedore.copy(image, "oci-archive:#{tar}:v1")
      assert Digest.compute(skopeo_raw("oci-archive:#{tar}:v1")) == digest
    end

    tool_test "Stevedore reads back an archive skopeo produced, preserving the manifest digest",
              ["skopeo"] do
      image = loadable_image("ociarchive-reverse")
      ours = tmp("oci")
      tar = tmp("oci") <> ".tar"
      assert {:ok, %{digest: digest}} = Stevedore.copy(image, "oci:#{ours}:v1")

      run!("skopeo", ["copy", "oci:#{ours}:v1", "oci-archive:#{tar}:v1"])

      final = tmp("oci")

      assert {:ok, %{digest: round_tripped}} =
               Stevedore.copy("oci-archive:#{tar}:v1", "oci:#{final}:v1")

      assert round_tripped == digest
    end
  end

  describe "docker-archive: (docker save tarball)" do
    tool_test "docker load accepts the archive and preserves the config digest as the image id",
              ["docker"] do
      # docker save/load is keyed on the *config* digest: `docker inspect .Id` == the config blob's
      # sha256. That equality across the load boundary is the docker-archive analogue of digest
      # stability (the OCI manifest digest is not preserved through this format).
      image = loadable_image("dockerload")
      tar = tmp("docker") <> ".tar"
      tag = "localhost/stevedore-9e/dockerload-#{System.unique_integer([:positive])}:t"
      assert {:ok, _} = Stevedore.copy(image, "docker-archive:#{tar}:#{tag}")

      on_exit(fn -> System.cmd(find("docker"), ["rmi", "-f", tag], stderr_to_stdout: true) end)

      run!("docker", ["load", "-i", tar])
      id = run!("docker", ["inspect", "--format", "{{.Id}}", tag])
      assert String.trim(id) == Digest.to_string(config_digest(image))
    end

    tool_test "skopeo reads the archive Stevedore wrote, agreeing on the config digest", [
      "skopeo"
    ] do
      # A daemon-free cross-check of the same invariant: skopeo's `--config` returns the config blob,
      # whose digest must equal the one Stevedore wrote.
      image = loadable_image("dockerarchive-skopeo")
      tar = tmp("docker") <> ".tar"
      tag = "stevedore-9e/da:v1"
      assert {:ok, _} = Stevedore.copy(image, "docker-archive:#{tar}:#{tag}")

      config = run!("skopeo", ["inspect", "--raw", "--config", "docker-archive:#{tar}"])
      assert Digest.compute(config) == config_digest(image)
    end

    tool_test "Stevedore reads back an archive skopeo produced, preserving the config digest",
              ["skopeo"] do
      image = loadable_image("dockerarchive-reverse")
      ours = tmp("oci")
      tar = tmp("docker") <> ".tar"
      assert {:ok, _} = Stevedore.copy(image, "oci:#{ours}:v1")

      run!("skopeo", ["copy", "oci:#{ours}:v1", "docker-archive:#{tar}:repo/x:t"])

      final = tmp("oci")
      assert {:ok, _} = Stevedore.copy("docker-archive:#{tar}", "oci:#{final}:v1")
      assert layout_config_digest(final, "v1") == config_digest(image)
    end
  end

  describe "dir: (skopeo flat directory)" do
    tool_test "skopeo reads the directory Stevedore wrote, agreeing on the manifest digest",
              ["skopeo"] do
      image = loadable_image("dir-skopeo")
      dir = tmp("dir")
      assert {:ok, %{digest: digest}} = Stevedore.copy(image, "dir:#{dir}")
      assert Digest.compute(skopeo_raw("dir:#{dir}")) == digest
    end

    tool_test "Stevedore reads back a directory skopeo produced, preserving the manifest digest",
              ["skopeo"] do
      image = loadable_image("dir-reverse")
      ours = tmp("oci")
      dir = tmp("dir")
      assert {:ok, %{digest: digest}} = Stevedore.copy(image, "oci:#{ours}:v1")

      run!("skopeo", ["copy", "oci:#{ours}:v1", "dir:#{dir}"])

      final = tmp("oci")
      assert {:ok, %{digest: round_tripped}} = Stevedore.copy("dir:#{dir}", "oci:#{final}:v1")
      assert round_tripped == digest
    end
  end

  describe "multi-arch index → oci: layout" do
    tool_test "skopeo enumerates every child of the index Stevedore wrote, with stable digests",
              ["skopeo"] do
      # image-layout + image-index: `copy(..., all: true)` writes the index and all children into the
      # layout. skopeo must see the same index digest and the same child digest for each platform.
      {src, index_digest, children} = seed_index(["amd64", "arm64"])
      out = tmp("oci")

      assert {:ok, %{digest: pushed}} = Stevedore.copy({src, "v1"}, "oci:#{out}:v1", all: true)
      assert pushed == index_digest

      raw = skopeo_raw("oci:#{out}:v1")
      assert Digest.compute(raw) == index_digest

      listed =
        raw
        |> JSON.decode!()
        |> Map.fetch!("manifests")
        |> Map.new(fn m -> {m["platform"]["architecture"], m["digest"]} end)

      for {arch, child_digest} <- children do
        assert listed[arch] == Digest.to_string(child_digest)
      end
    end
  end

  describe "media-type & compression fidelity" do
    tool_test "Docker v2s2 media types survive the oci-layout round-trip (no coercion to OCI)",
              ["skopeo"] do
      # A Docker-format manifest must stay Docker through the layout — re-tagging it as OCI would
      # both change the bytes (digest) and lie about the format. skopeo reads it back verbatim.
      image = loadable_image("docker-mediatype", format: :docker)
      assert image.manifest.media_type == MediaType.docker_manifest()

      dir = tmp("oci")
      assert {:ok, %{digest: digest}} = Stevedore.copy(image, "oci:#{dir}:v1")

      raw = skopeo_raw("oci:#{dir}:v1")
      assert Digest.compute(raw) == digest
      assert JSON.decode!(raw)["mediaType"] == MediaType.docker_manifest()
    end

    if Stevedore.Archive.zstd_available?() do
      tool_test "zstd-compressed layers round-trip through an oci-layout skopeo reads", ["skopeo"] do
        image = loadable_image("zstd", compression: :zstd)
        assert [%{descriptor: %{media_type: mt}}] = image.layers
        assert mt == MediaType.oci_layer_zstd()

        dir = tmp("oci")
        assert {:ok, %{digest: digest}} = Stevedore.copy(image, "oci:#{dir}:v1")
        assert Digest.compute(skopeo_raw("oci:#{dir}:v1")) == digest
      end
    else
      @tag skip: "ezstd not built (Stevedore.Archive.zstd_available? == false)"
      test "zstd-compressed layers round-trip through an oci-layout skopeo reads" do
        :ok
      end
    end
  end

  # --- helpers ---

  # A single-layer image with a *real* tar layer, so `docker load`/`podman load` can extract it (a
  # gzipped string is enough for digest checks but not for a daemon). Content is keyed on `label` so
  # each case has a distinct digest and never shares blobs by accident.
  defp loadable_image(label, opts \\ []) do
    content = "stevedore step-9e interop fixture: #{label}\n"

    entries = [
      %{
        name: "etc/#{label}.txt",
        type: :regular,
        mode: 0o644,
        size: byte_size(content),
        linkname: nil,
        content: content
      }
    ]

    {:ok, image} =
      Build.image(
        [entries],
        %{cmd: ["/bin/true"], labels: %{"step" => "9e", "case" => label}},
        opts
      )

    image
  end

  # A two-child index seeded into a source OCI layout, plus the digests to assert against.
  defp seed_index(arches) do
    children =
      Enum.map(arches, fn arch ->
        {:ok, image} =
          Build.image([layer_entries("idx-#{arch}")], %{}, platform: "linux/#{arch}")

        {arch, image}
      end)

    manifests =
      Enum.map(children, fn {arch, image} ->
        %{
          "mediaType" => image.manifest.media_type,
          "size" => byte_size(image.manifest.raw),
          "digest" => Digest.to_string(Image.digest(image)),
          "platform" => %{"os" => "linux", "architecture" => arch}
        }
      end)

    index_raw =
      JSON.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => MediaType.oci_index(),
        "manifests" => manifests
      })

    dir = tmp("idx-src")
    src = %Transport.OCILayout{path: dir}

    Enum.each(children, fn {_arch, image} ->
      Enum.each(image.blobs, fn {digest, bytes} ->
        :ok = Transport.OCILayout.put_blob(src, digest!(digest), bytes)
      end)

      {:ok, _} =
        Transport.OCILayout.put_manifest(src, nil, image.manifest.raw, image.manifest.media_type)
    end)

    {:ok, _} = Transport.OCILayout.put_manifest(src, "v1", index_raw, MediaType.oci_index())

    child_digests = Enum.map(children, fn {arch, image} -> {arch, Image.digest(image)} end)
    {src, Digest.compute(index_raw), child_digests}
  end

  defp layer_entries(name) do
    content = "#{name}\n"

    [
      %{
        name: name,
        type: :regular,
        mode: 0o644,
        size: byte_size(content),
        linkname: nil,
        content: content
      }
    ]
  end

  # A unique tmp path per call so re-runs and parallel cases never collide on disk.
  defp tmp(name),
    do: Path.join(System.tmp_dir!(), "stevedore-9e-#{name}-#{System.unique_integer([:positive])}")

  defp config_digest(%Image{config: config}), do: Digest.compute(config.raw)

  # The config descriptor digest recorded in a manifest written to an on-disk OCI layout.
  defp layout_config_digest(dir, ref) do
    layout = %Transport.OCILayout{path: dir}
    {:ok, fetched} = Transport.get_manifest(layout, ref)
    {:ok, manifest} = Manifest.parse(fetched.raw, fetched.media_type)
    {:ok, config} = Manifest.config(manifest)
    config.digest
  end

  defp digest!(string) do
    {:ok, digest} = Digest.parse(string)
    digest
  end

  # The raw manifest bytes an oracle reads from `ref`. We digest these directly: a match against
  # Stevedore's digest proves the tool read exactly the bytes we wrote.
  defp skopeo_raw(ref), do: run!("skopeo", ["inspect", "--raw", ref])

  # Run an oracle, asserting a clean exit and returning its stdout.
  defp run!(tool, args) do
    {out, code} = System.cmd(find(tool), args, stderr_to_stdout: true)
    assert code == 0, "`#{tool} #{Enum.join(args, " ")}` exited #{code}:\n#{out}"
    out
  end
end
