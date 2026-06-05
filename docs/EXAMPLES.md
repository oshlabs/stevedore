# Examples

A worked tour of everything Stevedore can do, organized by the **at-rest image lifecycle**.

> **Status.** Stevedore is pre-1.0. These examples illustrate the **target API** from the design
> (`tmp/PLAN.md §6`); each section is tagged with the phase that delivers it (`[P1]`…`[P7]`).
> Examples are kept truthful as phases land — anything tagged with an unshipped phase is the
> intended shape, not yet callable. Runnable, deterministic snippets also live as `iex>`
> **doctests** in the module `@doc`s; this file is the cross-cutting, end-to-end guide.

Reference syntax follows Skopeo's transport-prefixed form: `docker://`, `oci:`, `oci-archive:`,
`docker-archive:`, `dir:` (see `docs/REFERENCES.md` → containers-transports(5)).

---

## Core data types `[P0/P1]`

```elixir
# Parse and normalize an image reference (Docker/OCI rules).
{:ok, ref} = Stevedore.Reference.parse("alpine:3.20")
ref.registry    #=> "registry-1.docker.io"
ref.repository  #=> "library/alpine"      # single-name repos get the library/ prefix
ref.tag         #=> "3.20"

{:ok, ref} = Stevedore.Reference.parse("ghcr.io/owner/app@sha256:0a1b…")
ref.digest      #=> %Stevedore.Digest{algorithm: :sha256, hex: "0a1b…"}

# Compute and verify content digests (over raw bytes).
d = Stevedore.Digest.compute("hello", :sha256)
to_string(d)                       #=> "sha256:2cf24d…"
Stevedore.Digest.verify("hello", d) #=> :ok
Stevedore.Digest.to_path(d)        #=> "sha256/2cf24d…"   # blob layout path
```

## Fetch / inspect `[P1]`

```elixir
{:ok, ref} = Stevedore.Reference.parse("docker.io/library/alpine:3.20")

# Inspect without pulling layers.
{:ok, manifest} = Stevedore.inspect(ref)
Stevedore.Manifest.kind(manifest)  #=> :index        # multi-arch image
{:ok, descriptors} = Stevedore.Manifest.manifests(manifest)

# The raw, digest-preserving fetch Tank consumes (anonymous bearer auth handled internally).
{:ok, %{media_type: mt, digest: dg, raw: raw, json: json}} =
  Stevedore.Registry.manifest(ref, [])
Stevedore.Digest.compute(raw) == dg   #=> true        # digest is over raw bytes

# Select the host platform from an index, then fetch that manifest's config + a layer.
{:ok, sub} = Stevedore.Manifest.select(manifest, os: "linux", architecture: "arm64")
{:ok, config_bytes} = Stevedore.Registry.blob(ref, sub.digest, [])

# Raw / config inspection shapes (skopeo inspect --raw / --config).
{:ok, raw}    = Stevedore.inspect(ref, raw: true)
{:ok, config} = Stevedore.inspect(ref, config: true)

# Tags and a bare manifest digest.
{:ok, tags}   = Stevedore.list_tags(ref)
"sha256:" <> _ = to_string(Stevedore.manifest_digest(raw))
```

### Authentication `[P1]`

```elixir
# Anonymous is the default. Provide basic creds or read ~/.docker/config.json.
{:ok, _} = Stevedore.Registry.manifest(ref, creds: {:basic, "user", "token"})
{:ok, auths} = Stevedore.Auth.from_docker_config(nil)   # nil = default location
```

## Copy / mirror `[P2]`

`copy` is the primitive — any transport to any transport, digests preserved by default.

```elixir
# Pull a registry image into a local OCI layout (one host platform, default).
{:ok, _} = Stevedore.copy("docker://alpine:3.20", "oci:./alpine-layout:3.20")

# Mirror an entire multi-arch index between registries.
{:ok, _} = Stevedore.copy("docker://alpine:3.20", "docker://ghcr.io/me/alpine:3.20", all: true)

# Copy specific platforms, converting OCI -> Docker v2s2 (this changes the manifest digest).
{:ok, _} =
  Stevedore.copy("docker://alpine:3.20", "dir:./out",
    platforms: ["linux/amd64", "linux/arm64"],
    format: :v2s2
  )

# Round-trip into a docker save tarball and back — layer/manifest digests stay stable.
{:ok, _} = Stevedore.copy("oci:./alpine-layout:3.20", "docker-archive:./alpine.tar:alpine:3.20")

# Bulk sync from a declarative spec.
{:ok, results} =
  Stevedore.sync([
    {"docker://alpine:3.20", "docker://ghcr.io/me/alpine:3.20"},
    {"docker://debian:12",   "docker://ghcr.io/me/debian:12"}
  ])

# Delete a tag/manifest from a transport.
:ok = Stevedore.delete("docker://ghcr.io/me/alpine:3.20")
```

## Create / build (declarative) `[P4]`

No build-by-running — Stevedore *assembles* images from layers/rootfs + config.

```elixir
# Assemble an image from layer tarballs + a config map.
{:ok, image} =
  Stevedore.Build.image(
    [File.read!("rootfs-layer.tar.gz")],
    %{entrypoint: ["/bin/app"], env: ["LANG=C.UTF-8"], working_dir: "/srv"},
    platform: "linux/amd64", format: :oci
  )

# Single-layer image from a directory tree (deterministic -> reproducible digest).
{:ok, image} = Stevedore.Build.from_dir("./rootfs", %{cmd: ["/bin/sh"]})

# Append a layer (crane append) and push the result.
{:ok, image} = Stevedore.Build.append(image, File.read!("patch-layer.tar.gz"))
{:ok, _}     = Stevedore.copy(image, "docker://ghcr.io/me/app:1.0")
```

## Modify / mutate `[P4]`

```elixir
# Rewrite config — accepts a change map or a function.
image = Stevedore.Mutate.config(image, %{entrypoint: ["/bin/app", "--prod"], user: "1000:1000"})
image = Stevedore.Mutate.config(image, fn cfg -> %{cfg | env: ["DEBUG=0" | cfg.env]} end)

# Annotations, retag, rebase onto a new base image, flatten to one layer.
image            = Stevedore.Mutate.annotations(image, %{"org.opencontainers.image.source" => "https://…"})
image            = Stevedore.Mutate.retag(image, "1.0.1")
{:ok, rebased}   = Stevedore.Mutate.rebase(image, old_base, new_base)
{:ok, flattened} = Stevedore.Mutate.flatten(image)
```

## Analyze `[P5]`

Read what's inside an image — in memory, no root, whiteout-aware.

```elixir
{:ok, image} = Stevedore.inspect("docker://debian:12") |> with_layers()

# A single layer's tar entries.
{:ok, entries} = Stevedore.Layer.entries(hd(image.layers))

# The effective merged filesystem across the whole layer stack (honors .wh. + .wh..wh..opq).
{:ok, tree} = Stevedore.Layer.merged_view(image)
tree["/etc/os-release"].type  #=> :regular

# Diff two layers; query and read files from the merged view.
{:ok, %{added: a, modified: m, removed: r}} = Stevedore.Layer.diff(layer_a, layer_b)
{:ok, nodes}   = Stevedore.Analyze.files(image, ~r{^/usr/bin/})
{:ok, release} = Stevedore.Analyze.read_file(image, "/etc/os-release")

# Best-effort SBOM (os-release, dpkg/apk db, language manifests).
{:ok, sbom} = Stevedore.Analyze.sbom(image)
```

## Sign / verify / referrers (OCI 1.1) `[P6]`

```elixir
# Sign an image (cosign-compatible) and verify against a policy.
{:ok, sig_desc} = Stevedore.Sign.sigstore(image, my_key)
{:ok, [_passed]} = Stevedore.Verify.image(image, %{keys: [my_pubkey], require: :any})

# Attach an arbitrary artifact (e.g. an SBOM) to a subject image, then list referrers.
{:ok, _} = Stevedore.Referrers.attach("docker://ghcr.io/me/app:1.0", subject_digest, sbom_artifact)
{:ok, index} = Stevedore.Referrers.list("docker://ghcr.io/me/app:1.0", subject_digest,
                 artifact_type: "application/spdx+json")
```

## Serve `[P3]`

```elixir
# Standalone /v2 registry (Bandit). Nothing starts unless you call this.
{:ok, _pid} =
  Stevedore.start_link(
    port: 5000,
    store: {Stevedore.Store.Local, root: "/var/lib/stevedore"},
    authorize: fn _conn, action, _scope -> if action == :pull, do: :ok, else: {:error, :unauthorized} end
  )
# Now: crane/skopeo/docker can pull (and, if authorized, push) against localhost:5000.

# Or mount the API inside a host Plug router.
forward("/v2", to: Stevedore.Plug, init_opts: [store: {Stevedore.Store.Local, root: "…"}])
```

## Deploy as a static registry `[P7]`

```elixir
# Generate a static v2 tree + a web-server config that serves it as a read-only registry.
{:ok, _} = Stevedore.Deploy.tree("docker://alpine:3.20", "./public", platforms: ["linux/amd64"])
{:ok, conf} = Stevedore.Deploy.nginx_config("./public")
File.write!("alpine-registry.nginx.conf", conf)
# A dumb web server now serves ./public at /v2/... with the right headers.
```

## CLI `[P7]`

Thin `mix` shells over the same verbs:

```sh
mix stevedore.copy docker://alpine:3.20 oci:./alpine:3.20 --all
mix stevedore.inspect docker://alpine:3.20 --config
mix stevedore.list_tags docker://library/alpine
mix stevedore.sync ./sync.yaml
mix stevedore.delete docker://ghcr.io/me/alpine:3.20
```
