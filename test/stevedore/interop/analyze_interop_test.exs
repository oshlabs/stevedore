defmodule Stevedore.Interop.AnalyzeInteropTest do
  @moduledoc """
  Strategy 3 (part 4 of 4) — **merged-filesystem interop**. `Stevedore.Analyze` reconstructs an
  image's effective root filesystem in memory (stacking layers, applying OCI whiteouts) via
  `Stevedore.Layer.merged_view/2`. An independent implementation that materializes the *same* merged
  rootfs is the authoritative cross-check for layer-ordering and whiteout bugs a self-test can't find:
  if Stevedore and the oracle disagree on which files survive, one of them is wrong.

  ## Oracles, and why two of them

    * `crane export IMAGE -` streams the merged rootfs of an image as a tar (go-containerregistry's
      `mutate.Extract`). It is the primary oracle for **file listing / content parity** and for the
      `.wh.<name>` **deletion** whiteout — the cases the plan calls the core bug-finder.
    * `crane export` does **not** implement the *opaque-directory* whiteout (`.wh..wh..opq`):
      go-containerregistry's extractor only strips the `.wh.` prefix and tombstones that single name,
      so a directory's lower-layer contents leak through (verified 2026-06-06 with crane 0.21.6).
      For the opaque case we therefore use a **runtime-grade** extractor — `podman create` +
      `podman export`, which honors opaque dirs through containers/storage — as the oracle instead.

  ## Hermetic where it can be

  The listing/content/`.wh.` cases build tiny **from-scratch** images (no base, no network): crane
  export only unpacks layer tars, so no runnable `/bin` is needed. Only the SBOM case pulls a real
  distro image (`alpine`, pinned by digest) and so needs network; it is gated behind a Docker Hub
  reachability probe and skips cleanly otherwise. Tag: `:interop`. Cases skip cleanly when their
  oracle (`crane`/`podman`) is absent (`Stevedore.TestTools`).

      mix test --include interop test/stevedore/interop/analyze_interop_test.exs

  Specs / tool docs:
    * image-spec layer (whiteouts, "Representing Changes") —
      <https://github.com/opencontainers/image-spec/blob/main/layer.md#representing-changes>
    * `crane export` — <https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane_export.md>
    * go-containerregistry `mutate.Extract` (opaque-whiteout limitation) —
      <https://github.com/google/go-containerregistry/blob/main/pkg/v1/mutate/mutate.go>
    * `podman export` / `podman create` —
      <https://docs.podman.io/en/latest/markdown/podman-export.1.html>
    * os-release — <https://www.freedesktop.org/software/systemd/man/latest/os-release.html>
  """
  use ExUnit.Case, async: false

  import Stevedore.TestTools, only: [tool_test: 3, find: 1, available?: 1]

  alias Stevedore.{Analyze, Archive, Build, Config, Digest, Image, Manifest, Transport}

  @moduletag :interop

  # alpine pinned by digest (resolved 2026-06-06; see Stevedore.Fixtures).
  @alpine Stevedore.Fixtures.image("alpine:3.20")
  @docker_hub "https://registry-1.docker.io"

  describe "merged file set vs crane export" do
    tool_test "the merged file listing equals crane's exported rootfs (no whiteouts)", ["crane"] do
      # A two-layer from-scratch image with files spread across nested dirs and no overwrites: the
      # merged set is the union of both layers. crane unpacks the layers and must surface exactly the
      # same regular files Stevedore's merged_view does.
      lower = [
        file("bin/sh", "sh\n"),
        file("etc/hosts", "127.0.0.1 localhost\n"),
        file("etc/conf/a.conf", "a\n"),
        file("var/log/old.log", "old\n")
      ]

      upper = [file("usr/bin/tool", "tool\n"), file("etc/conf/b.conf", "b\n")]

      {:ok, image} = Build.image([Archive.write!(lower), Archive.write!(upper)], scratch())

      assert regular_files(crane_rootfs(image)) == analyze_regular_paths(image)
    end

    tool_test "a file overwritten in a later layer reads back as the top layer's bytes", ["crane"] do
      # image-spec layer ordering: the top-most occurrence of a path wins. Analyze.read_file must
      # return the upper bytes, byte-for-byte identical to what crane extracts (sha256 compared). A
      # lower-only file is also checked to prove non-overwritten content survives unchanged.
      lower = [file("app/data.txt", "first\n"), file("shared/keep.txt", "keep\n")]
      upper = [file("app/data.txt", "second\n")]

      {:ok, image} = Build.image([Archive.write!(lower), Archive.write!(upper)], scratch())

      rootfs = crane_rootfs(image)

      assert {:ok, "second\n"} = Analyze.read_file(image, "app/data.txt")
      assert Digest.compute("second\n") == Digest.compute(crane_content(rootfs, "app/data.txt"))

      assert {:ok, "keep\n"} = Analyze.read_file(image, "shared/keep.txt")
      assert Digest.compute("keep\n") == Digest.compute(crane_content(rootfs, "shared/keep.txt"))
    end

    tool_test "a .wh. whiteout deletes the file in both crane's rootfs and Analyze", ["crane"] do
      # The core bug-finder: layer 2 carries `data/.wh.gone.txt`, deleting `data/gone.txt` from layer
      # 1 while `data/keep.txt` stays. image-spec layer.md "Whiteouts". Both tools must agree the file
      # is gone and the sibling remains.
      lower = [file("data/keep.txt", "keep\n"), file("data/gone.txt", "gone\n")]
      upper = [whiteout("data/.wh.gone.txt")]

      {:ok, image} = Build.image([Archive.write!(lower), Archive.write!(upper)], scratch())

      crane_paths = regular_files(crane_rootfs(image))
      analyze_paths = analyze_regular_paths(image)

      assert "data/keep.txt" in crane_paths and "data/keep.txt" in analyze_paths
      refute "data/gone.txt" in crane_paths
      refute "data/gone.txt" in analyze_paths
      assert crane_paths == analyze_paths
      assert {:error, :enoent} = Analyze.read_file(image, "data/gone.txt")
    end
  end

  describe "opaque directory (.wh..wh..opq) vs podman export" do
    tool_test "an opaque dir hides all lower entries, agreeing with a runtime extractor", [
      "podman"
    ] do
      # `opq/.wh..wh..opq` in layer 2 opaques `opq/`: only the upper layer's `opq/` entries survive,
      # while a sibling dir is untouched. crane export can't model this (see @moduledoc), so the
      # oracle here is `podman create` + `podman export`, a runtime-grade extractor that honors
      # opaque whiteouts. Stevedore's merged_view must reach the same merged set.
      lower = [
        file("opq/lower1.txt", "l1\n"),
        file("opq/lower2.txt", "l2\n"),
        file("other/keep.txt", "keep\n")
      ]

      upper = [opaque("opq/.wh..wh..opq"), file("opq/upper.txt", "up\n")]

      {:ok, image} = Build.image([Archive.write!(lower), Archive.write!(upper)], scratch())

      podman_paths = regular_files(podman_rootfs(image))
      analyze_paths = analyze_regular_paths(image)

      # The opaque'd dir keeps only the upper entry; the lower entries are gone from both views.
      assert "opq/upper.txt" in podman_paths and "opq/upper.txt" in analyze_paths
      refute "opq/lower1.txt" in analyze_paths
      refute "opq/lower2.txt" in analyze_paths
      # The unrelated dir is untouched by the opaque marker.
      assert "other/keep.txt" in analyze_paths
      assert podman_paths == analyze_paths
    end
  end

  # The SBOM case needs a real distro image; gate it on Docker Hub reachability so a tool-only machine
  # still gets a clean hermetic skip (mirrors run_interop_test's compile-time network probe).
  if available?("crane") and Stevedore.TestTools.registry_up?(@docker_hub) do
    describe "SBOM vs crane export of a real image" do
      tool_test "Analyze.sbom surfaces alpine's os-release and full apk package set", ["crane"] do
        # Analyze.sbom is a heuristic parser over /etc/os-release and the apk db. Cross-check it
        # against the *same* files as crane extracts them: the OS identity must match os-release, and
        # the package count must equal the number of `P:` records in the apk database — proving the
        # parser found every package, not a subset.
        image = pull_image(@alpine)
        assert {:ok, sbom} = Analyze.sbom(image)

        rootfs = crane_rootfs(image)
        os_release = crane_content(rootfs, "etc/os-release")
        apk_db = crane_content(rootfs, "lib/apk/db/installed")

        assert sbom["os"]["ID"] == "alpine"
        assert sbom["os"]["VERSION_ID"] == os_release_field(os_release, "VERSION_ID")

        packages = sbom["packages"]
        assert Enum.all?(packages, &(&1["type"] == "apk"))

        # apk db: one `P:<name>` line per installed package. Equality (not ⊇) catches dropped records.
        assert length(packages) == length(Regex.scan(~r/^P:/m, apk_db))
        assert Enum.any?(packages, &(&1["name"] == "alpine-baselayout"))
      end
    end
  else
    @tag skip: "SBOM interop needs crane and a reachable Docker Hub"
    test "Analyze.sbom vs crane export (skipped: no crane or no network)" do
      :ok
    end
  end

  # --- fixtures ---

  defp scratch, do: %{cmd: ["/bin/true"], labels: %{"step" => "9h"}}

  defp file(name, content) do
    %{
      name: name,
      type: :regular,
      mode: 0o644,
      size: byte_size(content),
      linkname: nil,
      content: content
    }
  end

  # A `.wh.<name>` deletion marker / a `.wh..wh..opq` opaque marker: a zero-length regular tar entry
  # whose *name* carries the whiteout semantics (image-spec layer.md).
  defp whiteout(name),
    do: %{name: name, type: :regular, mode: 0o644, size: 0, linkname: nil, content: ""}

  defp opaque(name), do: whiteout(name)

  # Pulls a real image into an in-memory Image.t() (manifest + parsed config + layer blobs) so the
  # Analyze surface — which takes an Image — can run against it. copy/3 resolves a single platform.
  defp pull_image(ref) do
    dir = fresh(tmp("pull-oci"))
    {:ok, _} = Stevedore.copy("docker://#{ref}", "oci:#{dir}:v1")

    layout = %Transport.OCILayout{path: dir}
    {:ok, fetched} = Transport.get_manifest(layout, "v1")
    {:ok, manifest} = Manifest.parse(fetched.raw, fetched.media_type)
    {:ok, config_desc} = Manifest.config(manifest)
    {:ok, layers} = Manifest.layers(manifest)
    {:ok, config_raw} = Transport.get_blob(layout, config_desc.digest)
    {:ok, config} = Config.parse(config_raw)

    blobs =
      Enum.reduce([config_desc | layers], %{}, fn desc, acc ->
        {:ok, bytes} = Transport.get_blob(layout, desc.digest)
        Map.put(acc, to_string(desc.digest), bytes)
      end)

    %Image{manifest: manifest, config: config, layers: layers, blobs: blobs}
  end

  # --- oracles ---

  # The merged rootfs as crane sees it: write the image to a docker-archive, stream it through
  # `crane export - <out>` (crane reads the image tarball from stdin), and parse the resulting tar
  # with our own Archive reader. Returns the rootfs as Archive entries.
  defp crane_rootfs(image) do
    in_tar = fresh(tmp("da") <> ".tar")
    out_tar = fresh(tmp("rootfs") <> ".tar")
    {:ok, _} = Stevedore.copy(image, "docker-archive:#{in_tar}:stevedore-9h/analyze:v1")

    # crane export takes the image on stdin (`-`); System.cmd can't pipe a file, so redirect via sh.
    run!("sh", ["-c", "#{find("crane")} export - #{out_tar} < #{in_tar}"])

    {:ok, entries} = Archive.read(File.read!(out_tar))
    entries
  end

  # The merged rootfs as a runtime sees it: load an oci-archive, `podman create` a container (without
  # running it) and `podman export` its filesystem. This honors opaque-dir whiteouts crane can't.
  defp podman_rootfs(image) do
    tar = fresh(tmp("oci") <> ".tar")
    {:ok, _} = Stevedore.copy(image, "oci-archive:#{tar}:v1")

    name = loaded_name(run!("podman", ["load", "-i", tar]))
    cid = String.trim(run!("podman", ["create", name]))

    on_exit(fn ->
      System.cmd(find("podman"), ["rm", "-f", cid], stderr_to_stdout: true)
      System.cmd(find("podman"), ["rmi", "-f", name], stderr_to_stdout: true)
    end)

    {out, 0} = System.cmd(find("podman"), ["export", cid])
    {:ok, entries} = Archive.read(out)
    entries
  end

  defp loaded_name(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "Loaded image: ", parts: 2) do
        [_, name] -> String.trim(name)
        _ -> nil
      end
    end)
  end

  # --- comparison helpers ---

  # The set of regular-file paths in a rootfs the oracle produced. Directories/symlinks are excluded
  # so the comparison is over file *contents* the merge decided on — crane omits parent-dir entries
  # our from-scratch fixtures never add, so a set over regular files is the apples-to-apples surface.
  defp regular_files(entries) do
    for %{type: :regular} = e <- entries, into: MapSet.new(), do: normalize(e.name)
  end

  defp analyze_regular_paths(image) do
    {:ok, nodes} = Analyze.files(image, fn _ -> true end)
    for %{type: :regular} = n <- nodes, into: MapSet.new(), do: n.path
  end

  defp crane_content(entries, path) do
    target = normalize(path)

    %{content: content} =
      Enum.find(entries, &(normalize(&1.name) == target and &1.type == :regular))

    content
  end

  defp os_release_field(contents, key) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "=", parts: 2) do
        [^key, value] -> value |> String.trim() |> String.trim("\"")
        _ -> nil
      end
    end)
  end

  # crane/podman tars name regular files without a leading "./" or trailing "/"; normalize defensively
  # so the set comparison matches Analyze's already-normalized paths.
  defp normalize(name) do
    name |> String.replace_prefix("./", "") |> String.replace_suffix("/", "")
  end

  # --- shelling & tmp ---

  defp run!(tool, args) do
    {out, code} = System.cmd(find(tool), args, stderr_to_stdout: true)
    assert code == 0, "`#{tool} #{Enum.join(args, " ")}` exited #{code}:\n#{out}"
    out
  end

  defp tmp(name),
    do: Path.join(System.tmp_dir!(), "stevedore-9h-#{name}-#{System.unique_integer([:positive])}")

  # `unique_integer` restarts per VM, so a tmp path can collide with a stale file from a prior run.
  # Writing an existing oci-archive/docker-archive *appends* to its index, which oracles then refuse;
  # clear the path first so every copy is fresh.
  defp fresh(path) do
    File.rm_rf!(path)
    path
  end
end
