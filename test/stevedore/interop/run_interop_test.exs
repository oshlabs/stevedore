defmodule Stevedore.Interop.RunInteropTest do
  @moduledoc """
  Strategy 3 (part 2 of 4) — **run the output of a build/mutate**. The only conclusive proof that an
  image Stevedore assembled is well-formed is to hand it to a real container runtime and execute it:
  a runtime rejects a bad rootfs (diff_id mismatch), a malformed config, or a manifest a daemon
  won't load — none of which a schema check or a self round-trip would catch.

  > Running the *output of a build* is **not** a violation of Stevedore's "never run containers"
  > invariant (AGENTS.md). Stevedore still runs nothing; the test harness invokes `podman`/`docker`
  > as oracles, exactly as the other interop steps shell out to `skopeo`/`crane`.

  ## What we assert

    * **A from-scratch image runs** its configured entrypoint/cmd with the expected stdout/exit code.
    * **Config fields are honored by the runtime** — `Env`, `WorkingDir`, `User` are observed inside
      the container, not merely present in the JSON. This is the real test that our config encoding
      is correct, not just schema-valid (image-spec config `config` object).
    * **Layer ordering is correct** — a file written in a later layer shadows the same path from an
      earlier one at runtime, which only holds if diff_ids and layer order are right.
    * **Mutations survive a real load** — `Mutate.config`/`flatten`/`rebase` produce images a runtime
      still runs with the mutated behavior; `annotations` land where an oracle (`skopeo`) sees them.
    * **Cross-runtime** — the same bytes load and run under both `podman` and `docker`, catching
      runtime-specific manifest strictness.

  ## How the image reaches the runtime

  Built images are handed to the runtime two ways, both exercising a real transport:

    * `oci-archive:` + `podman load` / `docker load` (default; preserves our **OCI** manifest bytes
      rather than the lossy Docker-schema2 conversion, so the runtime parses exactly what we wrote).
    * push to the compose `registry:2` + `podman run --tls-verify=false` (the registry path; skipped
      cleanly when the compose stack is down — see `registry_test/3`).

  ## Hermetic? No — and deliberately so

  Unlike the on-disk interop step (9E), these cases need a real rootfs to execute, so the base layer
  is busybox **pulled by digest** (`Stevedore.Fixtures.image("busybox:1.36")`). busybox is a single
  static binary providing `sh`/`env`/`pwd`/`id`/`cat`, which lets us observe config fields at
  runtime. The pull is memoized once per run. Tag: `:interop`; the whole suite skips cleanly without
  `podman` or a reachable Docker Hub.

      docker compose -f docker-compose.test.yml up -d   # only for the registry push case
      mix test --include interop test/stevedore/interop/run_interop_test.exs

  Specs / tool docs:
    * image-spec config — <https://github.com/opencontainers/image-spec/blob/main/config.md>
    * image-spec layer (diff_ids / ordering) —
      <https://github.com/opencontainers/image-spec/blob/main/layer.md>
    * `podman run` / `podman load` — <https://docs.podman.io/en/latest/markdown/podman-run.1.html>,
      <https://docs.podman.io/en/latest/markdown/podman-load.1.html>
    * `skopeo inspect` — <https://github.com/containers/skopeo/blob/main/docs/skopeo-inspect.1.md>
  """
  use ExUnit.Case, async: false

  import Stevedore.TestTools, only: [tool_test: 3, registry_test: 3, find: 1, available?: 1]

  alias Stevedore.{Archive, Build, Image, Manifest, Mutate, Transport}

  @moduletag :interop

  # busybox pinned by digest (resolved 2026-06-06; see Stevedore.Fixtures).
  @busybox Stevedore.Fixtures.image("busybox:1.36")

  # A cheap TCP probe (Docker Hub :443) decides skip-vs-run at compile time, mirroring
  # `registry_test/3`. `available?("podman")` short-circuits the probe so a machine without a runtime
  # never reaches out to the network just to compile the hermetic suite.
  @docker_hub "https://registry-1.docker.io"

  if available?("podman") and Stevedore.TestTools.registry_up?(@docker_hub) do
    describe "build from scratch → run" do
      tool_test "a from-scratch image runs its configured entrypoint and cmd", ["podman"] do
        {:ok, image} =
          Build.image([busybox()], %{entrypoint: ["/bin/echo"], cmd: ["scratch-runs"]})

        {out, code} = run_built(image, "scratch-entrypoint")
        assert code == 0
        assert last_line(out) == "scratch-runs"
      end

      tool_test "the runtime honors the configured env, working_dir, and user", ["podman"] do
        # image-spec config: Env / WorkingDir / User. We don't trust the JSON — we observe each one
        # from inside the running container via busybox applets.
        {:ok, image} =
          Build.image([busybox()], %{
            env: ["STEVEDORE=9f", "PATH=/bin"],
            working_dir: "/tmp",
            user: "1234"
          })

        tag = load_built(image, "config-fields")

        assert {env, 0} = run(tag, ["--entrypoint", "/bin/env"])
        assert env =~ "STEVEDORE=9f"

        assert {pwd, 0} = run(tag, ["--entrypoint", "/bin/pwd"])
        assert last_line(pwd) == "/tmp"

        assert {uid, 0} = run(tag, ["--entrypoint", "/bin/id"], ["-u"])
        assert last_line(uid) == "1234"
      end

      tool_test "a later layer shadows an earlier layer at runtime (ordering / diff_ids)",
                ["podman"] do
        # Only true if layer order and diff_ids are correct: the runtime stacks layers bottom-to-top,
        # so the top layer's /data/x wins. A swapped order or wrong diff_id would surface here.
        lower = [file("data/x", "lower\n")]
        upper = [file("data/x", "upper\n")]

        {:ok, image} =
          Build.image([busybox(), Archive.write!(lower), Archive.write!(upper)], %{
            entrypoint: ["/bin/cat"],
            cmd: ["/data/x"]
          })

        {out, code} = run_built(image, "shadow")
        assert code == 0
        assert last_line(out) == "upper"
      end
    end

    describe "mutate → run" do
      tool_test "Mutate.config changes the entrypoint/env the runtime honors, base layers intact",
                ["podman"] do
        {:ok, base} =
          Build.image([busybox()], %{entrypoint: ["/bin/echo"], cmd: ["before"], env: ["V=old"]})

        mutated =
          Mutate.config(base, %{entrypoint: ["/bin/echo"], cmd: ["after"], env: ["V=new"]})

        # Mutating the config must not touch the layers (the base rootfs is reused byte-for-byte).
        assert mutated.layers == base.layers

        tag = load_built(mutated, "mutate-config")

        assert {out, 0} = run(tag, [])
        assert last_line(out) == "after"

        assert {env, 0} = run(tag, ["--entrypoint", "/bin/env"])
        assert env =~ "V=new"
        refute env =~ "V=old"
      end

      tool_test "Mutate.flatten collapses to a single layer that still runs identically",
                ["podman", "skopeo"] do
        # crane/skopeo semantics: flatten merges all layers into one. The runtime must still find the
        # app file (behavior preserved), and the on-disk manifest must show exactly one layer.
        {:ok, multi} =
          Build.image([busybox(), Archive.write!([file("app/hello.txt", "flat-hello\n")])], %{
            entrypoint: ["/bin/cat"],
            cmd: ["/app/hello.txt"]
          })

        assert length(Image.layers(multi)) == 2
        assert {:ok, flat} = Mutate.flatten(multi)
        assert length(Image.layers(flat)) == 1

        {out, code} = run_built(flat, "flatten")
        assert code == 0
        assert last_line(out) == "flat-hello"

        # A different tool agrees the flattened image carries a single layer.
        assert skopeo_layer_count(flat) == 1
      end

      tool_test "Mutate.rebase moves the app layer onto a new base that still runs", ["podman"] do
        # crane rebase: swap the bottom (old base) layers for new_base's, keeping the app layers on
        # top. The result must still run the app, now atop a different (but still busybox) base.
        bb = busybox()
        {:ok, old_base} = Build.image([bb], %{})

        {:ok, new_base} =
          Build.image([bb, Archive.write!([file("etc/marker", "rebased\n")])], %{})

        {:ok, app} =
          Build.image([bb, Archive.write!([file("app/hello.txt", "app\n")])], %{
            entrypoint: ["/bin/cat"]
          })

        assert {:ok, rebased} = Mutate.rebase(app, old_base, new_base)
        # new_base's two layers, then the app layer on top.
        assert length(Image.layers(rebased)) == 3

        tag = load_built(rebased, "rebase")

        # The app layer still works on the new base...
        assert {app_out, 0} = run(tag, [], ["/app/hello.txt"])
        assert last_line(app_out) == "app"
        # ...and the new base's marker is present (proving the base really was swapped in).
        assert {marker, 0} = run(tag, [], ["/etc/marker"])
        assert last_line(marker) == "rebased"
      end

      tool_test "Mutate.rebase rejects a deliberately wrong base with :base_mismatch", ["podman"] do
        # The safety check: rebasing an image that does not start with `old_base`'s layers must fail
        # rather than silently produce a corrupt image. (Real busybox images, per the step's scope.)
        bb = busybox()

        {:ok, app} =
          Build.image([bb, Archive.write!([file("app/hello.txt", "app\n")])], %{})

        {:ok, wrong_base} = Build.image([Archive.write!([file("not/busybox", "x\n")])], %{})
        {:ok, other} = Build.image([Archive.write!([file("other/base", "y\n")])], %{})

        assert {:error, :base_mismatch} = Mutate.rebase(app, wrong_base, other)
      end

      tool_test "Mutate.annotations are visible to skopeo after a copy", ["skopeo"] do
        # image-spec manifest `annotations`. A config-level mutation that needs no runtime: push to an
        # OCI layout and let skopeo read the manifest back, confirming the annotation survived.
        {:ok, base} = Build.image([busybox()], %{cmd: ["/bin/true"]})

        mutated =
          Mutate.annotations(base, %{
            "org.opencontainers.image.title" => "stevedore-9f",
            "org.opencontainers.image.source" => "https://example.test/stevedore"
          })

        dir = fresh(tmp("oci"))
        assert {:ok, _} = Stevedore.copy(mutated, "oci:#{dir}:v1")

        raw = JSON.decode!(run!("skopeo", ["inspect", "--raw", "oci:#{dir}:v1"]))
        assert raw["annotations"]["org.opencontainers.image.title"] == "stevedore-9f"
        assert raw["annotations"]["org.opencontainers.image.source"] =~ "stevedore"
      end
    end

    describe "cross-runtime & registry" do
      tool_test "the same built image runs under both podman and docker", ["podman", "docker"] do
        # Same bytes, two daemons: docker and podman differ in manifest strictness, so a build that
        # only one accepts is a real interop bug. `docker load` reads only docker-archive (not
        # oci-archive), while podman reads both — so the shared format here is docker-archive, the
        # one tarball both daemons ingest.
        {:ok, image} =
          Build.image([busybox()], %{entrypoint: ["/bin/echo"], cmd: ["both-runtimes"]})

        tar = fresh(tmp("docker") <> ".tar")
        tag = "localhost/#{oci_ref("cross")}:v1"
        assert {:ok, _} = Stevedore.copy(image, "docker-archive:#{tar}:#{tag}")

        podman_tag = load_archive("podman", tar)
        docker_tag = load_archive("docker", tar)

        assert {pout, 0} = cmd("podman", ["run", "--rm", podman_tag])
        assert {dout, 0} = cmd("docker", ["run", "--rm", docker_tag])
        assert last_line(pout) == "both-runtimes"
        assert last_line(dout) == "both-runtimes"
      end

      registry_test "a built image pushed to registry:2 runs via podman run",
                    "http://localhost:5000" do
        # The registry path (vs. load): push our manifest+blobs to a real distribution server and let
        # podman pull+run it over plain HTTP (`--tls-verify=false`, the compose registry is insecure).
        {:ok, image} =
          Build.image([busybox()], %{entrypoint: ["/bin/echo"], cmd: ["via-registry"]})

        repo = "stevedore-9f/run-#{System.unique_integer([:positive])}"

        t = %Transport.Registry{
          registry: "localhost:5000",
          repository: repo,
          opts: [scheme: "http"]
        }

        assert {:ok, _} = Stevedore.copy(image, {t, "v1"})

        tag = "localhost:5000/#{repo}:v1"
        on_exit(fn -> cmd("podman", ["rmi", "-f", tag]) end)

        # podman prints pull progress to stderr (merged here); the container's own stdout is the
        # final line.
        assert {out, 0} = cmd("podman", ["run", "--rm", "--tls-verify=false", tag])
        assert last_line(out) == "via-registry"
      end
    end
  else
    @tag skip: "interop run suite needs podman and a reachable Docker Hub"
    test "build/mutate → run (skipped: no podman or no network)" do
      :ok
    end
  end

  # --- fixtures ---

  # busybox's uncompressed root layer tar, pulled by digest once and memoized for the run. Used as
  # the bottom layer of every built image so `podman run` has a real /bin to execute. Returns the
  # single layer tar (busybox is a one-layer image); kept as a binary layer input so `Build.image`
  # recompresses it and recomputes a matching diff_id.
  defp busybox do
    case :persistent_term.get({__MODULE__, :busybox}, nil) do
      nil ->
        tar = pull_busybox_rootfs()
        :persistent_term.put({__MODULE__, :busybox}, tar)
        tar

      tar ->
        tar
    end
  end

  defp pull_busybox_rootfs do
    dir = fresh(tmp("busybox-src"))
    {:ok, _} = Stevedore.copy("docker://#{@busybox}", "oci:#{dir}:v1")

    layout = %Transport.OCILayout{path: dir}
    {:ok, fetched} = Transport.get_manifest(layout, "v1")
    {:ok, manifest} = Manifest.parse(fetched.raw, fetched.media_type)
    {:ok, [layer | _]} = Manifest.layers(manifest)
    {:ok, compressed} = Transport.get_blob(layout, layer.digest)
    {:ok, tar} = Archive.gunzip(compressed)
    tar
  end

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

  # --- running ---

  # Build → oci-archive → `podman load` → `podman run --rm`, returning {stdout, exit_code}.
  defp run_built(image, label) do
    image |> load_built(label) |> run([])
  end

  # Build → oci-archive → `podman load`, returning the loaded local image name to `run/3`.
  defp load_built(image, label) do
    tar = fresh(tmp("oci") <> ".tar")
    ref = oci_ref(label)
    {:ok, _} = Stevedore.copy(image, "oci-archive:#{tar}:#{ref}")
    load_archive("podman", tar)
  end

  # `<runtime> load -i <tar>` of an oci-archive; returns the loaded image name the runtime assigned
  # (parsed from its "Loaded image:" line so we don't hard-code the naming scheme), and schedules its
  # removal.
  defp load_archive(runtime, tar) do
    {out, 0} = cmd(runtime, ["load", "-i", tar])
    name = loaded_name(out)
    on_exit(fn -> cmd(runtime, ["rmi", "-f", name]) end)
    name
  end

  defp loaded_name(load_output) do
    load_output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, "Loaded image: ", parts: 2) do
        [_, name] -> String.trim(name)
        _ -> nil
      end
    end)
  end

  # `podman run --rm <opts> <image> <cmd...>` — opts precede the image, cmd follows it (podman's
  # argument order). Returns {stdout, exit_code}.
  defp run(tag, opts, cmd \\ []) do
    cmd("podman", ["run", "--rm"] ++ opts ++ [tag] ++ cmd)
  end

  # --- oracles & shelling ---

  defp skopeo_layer_count(image) do
    dir = fresh(tmp("oci"))
    {:ok, _} = Stevedore.copy(image, "oci:#{dir}:v1")
    inspected = JSON.decode!(run!("skopeo", ["inspect", "oci:#{dir}:v1"]))
    length(inspected["Layers"])
  end

  defp last_line(output) do
    output |> String.split("\n", trim: true) |> List.last()
  end

  defp cmd(tool, args), do: System.cmd(find(tool), args, stderr_to_stdout: true)

  defp run!(tool, args) do
    {out, code} = cmd(tool, args)
    assert code == 0, "`#{tool} #{Enum.join(args, " ")}` exited #{code}:\n#{out}"
    out
  end

  # A unique, runtime-legal image ref name for an oci-archive (lowercase, no slash/colon).
  defp oci_ref(label), do: "stevedore9f-#{label}-#{System.unique_integer([:positive])}"

  defp tmp(name),
    do: Path.join(System.tmp_dir!(), "stevedore-9f-#{name}-#{System.unique_integer([:positive])}")

  # `unique_integer` restarts per VM, so a tmp path can collide with a leftover from a previous run.
  # Writing an `oci-archive:`/`oci:` target that already exists *appends* to its index (two images in
  # one archive), which a runtime then refuses to load. Clear the path first so every copy is fresh.
  defp fresh(path) do
    File.rm_rf!(path)
    path
  end
end
