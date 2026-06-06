# Cookbook

Task-oriented recipes for Stevedore. Each recipe states the **intent** (why you'd reach for it),
gives a **complete, copy-paste block**, and shows the **expected result** (the return shape, with
`#=>`). Start at the top for the common "pull / mirror / build" path; the later recipes cover
signing, serving, and deploying. The pure data types are collected in the
[Core building blocks](#core-building-blocks) appendix at the end.

> **Status.** Everything here runs against the **shipped API**. The small, deterministic snippets
> also live as `iex>` **doctests** in the module `@doc`s and are exercised by the test suite; this
> file is the cross-cutting, task-first guide. The only roadmap item beyond it is Tank integration,
> which lives in a separate repo.

### Conventions you'll see throughout

- **Reference syntax** is Skopeo's transport-prefixed form (see `docs/REFERENCES.md`):
  `docker://name:tag`, `oci:path[:tag]`, `oci-archive:path[:tag]`, `docker-archive:path[:tag]`,
  `dir:path`, `static:path[:tag]`.
- **Return shapes** follow the error rules in `AGENTS.md`: `{:ok, value}` / `{:error, reason}`,
  where `reason` is a subsystem `%...Error{}` (context-rich), a bare atom like `:not_found`
  (context-free), or `{:bad_input, _}` (caller mistake). Functions never `raise` for caller
  mistakes — except the `!`-suffixed ones (e.g. `Archive.write!/1`), which do.
- **Digests are over raw bytes.** Manifests carry both `raw` (the exact bytes) and decoded `json`;
  the digest is always of `raw`, so it stays stable as data moves.
- **Optional dependencies.** The `docker://` client needs `:req`; the registry server needs
  `:plug`/`:bandit`; zstd layers need `:ezstd`. Everything else is dependency-free. Calling a mode
  whose dep is missing raises a clear error. Recipes that need one say so up front.

---

## 1. Pull & inspect an image

**Intent:** see what's inside a remote image — manifest, config, tags — without managing the HTTP
client by hand. *(Needs `:req`.)*

```elixir
{:ok, ref} = Stevedore.Reference.parse("alpine:3.20")

# One-liners — fetch and decode for you (anonymous bearer auth + digest verification handled):
{:ok, manifest} = Stevedore.inspect(ref)                 #=> {:ok, %Stevedore.Manifest{}}
{:ok, raw}      = Stevedore.inspect(ref, raw: true)      #=> raw manifest bytes
{:ok, config}   = Stevedore.inspect(ref, config: true)   #=> {:ok, %Stevedore.Config{}} (host platform)
{:ok, config}   = Stevedore.inspect(ref, config: true, platform: [os: "linux", architecture: "arm64"])

{:ok, tags} = Stevedore.list_tags(ref)                   #=> {:ok, ["3.20", "latest", ...]} (paginated)
Stevedore.manifest_digest(raw)                           #=> %Stevedore.Digest{} (digest of any manifest bytes)
```

**Need the raw client?** Drop to `Stevedore.Registry` when you want the exact bytes a runtime
(e.g. Tank) consumes — manifest + blobs, digests verified against `Docker-Content-Digest`:

```elixir
{:ok, %{media_type: mt, digest: dg, raw: raw, json: json}} = Stevedore.Registry.manifest(ref)
Stevedore.Digest.compute(raw) == dg   #=> true

# Resolve a platform from an index, then fetch that child's config + a layer (digest-verified):
{:ok, manifest} = Stevedore.Manifest.parse(raw, mt)
{:ok, child}    = Stevedore.Manifest.select(manifest)            # host platform
{:ok, sub}      = Stevedore.Registry.manifest(%{ref | tag: nil, digest: child.digest})
{:ok, image}    = Stevedore.Manifest.parse(sub.raw, sub.media_type)
{:ok, cfg_desc} = Stevedore.Manifest.config(image)
{:ok, config_bytes} = Stevedore.Registry.blob(%{ref | tag: nil, digest: child.digest}, cfg_desc.digest)
```

Blob fetch is robust to CDN redirects: `req` strips the `Authorization` header on any cross-host
redirect, so the registry token never leaks to a presigned URL.

**Private repositories** — pass credentials explicitly, or load them from the Docker config:

```elixir
{:ok, _} = Stevedore.Registry.manifest(ref, creds: {:basic, "user", "token"})

{:ok, auths} = Stevedore.Auth.from_docker_config(nil)   # defaults to ~/.docker/config.json
#=> {:ok, %{"ghcr.io" => {:basic, "user", "pass"}, ...}}   (missing file -> {:ok, %{}})
```

---

## 2. Mirror, convert & select platforms

**Intent:** move an image between any two transports with **digests preserved by default**.
`Stevedore.copy/3` is the verb everything composes from: registry, OCI layout, tarball, or `dir:`
tree, in any direction. *(`docker://` endpoints need `:req`.)*

```elixir
# Pull a registry image into a local OCI layout (host platform by default):
{:ok, %{digest: d}} = Stevedore.copy("docker://alpine:3.20", "oci:./alpine:3.20")

# Mirror the whole multi-arch index between registries (every child preserved):
{:ok, _} = Stevedore.copy("docker://alpine:3.20", "docker://ghcr.io/me/alpine:3.20", all: true)

# Copy a single chosen platform (written as a plain manifest):
{:ok, _} = Stevedore.copy("docker://alpine:3.20", "oci:./arm", platform: "linux/arm64")

# Copy a subset of an index (rebuilds the index — this changes the index digest):
{:ok, _} = Stevedore.copy("docker://alpine:3.20", "dir:./out", platforms: ["linux/amd64", "linux/arm64"])

# Convert OCI <-> Docker v2s2 (re-serializes, so the manifest digest changes):
{:ok, _} = Stevedore.copy("oci:./alpine:3.20", "docker://ghcr.io/me/alpine:3.20", format: :docker)

# Round-trip through tarballs; on-disk round-trips keep the manifest digest stable:
{:ok, _} = Stevedore.copy("oci:./alpine:3.20", "oci-archive:./alpine.oci.tar:3.20")
{:ok, _} = Stevedore.copy("oci:./alpine:3.20", "docker-archive:./alpine.docker.tar:alpine:3.20")
```

**Blob-skip and mount happen automatically:** before transferring a blob, `copy` checks
`has_blob?` on the destination and skips it; on registry→registry copies it tries a cross-repo
mount first. So re-copying is cheap and idempotent.

**Driving transports directly** — when you want the structs, not the string sugar (e.g. to set
registry options, or to target a `Static` tree with an explicit repository name):

```elixir
{:ok, {transport, ref}} = Stevedore.Transport.Parse.parse("docker://alpine:3.20", scheme: "https")

# Every transport answers the same interface (dispatched on the struct):
{:ok, fetched} = Stevedore.Transport.get_manifest(transport, ref)
{:ok, bytes}   = Stevedore.Transport.get_blob(transport, fetched.digest)
true_or_false  = Stevedore.Transport.has_blob?(transport, fetched.digest)

# A Static tree sink needs a repository name; copy fills it from a registry source, or set it:
static = %Stevedore.Transport.Static{path: "./public", name: "library/alpine"}
{:ok, _} = Stevedore.copy("docker://alpine:3.20", {static, "3.20"})
```

---

## 3. Bulk sync & delete

**Intent:** mirror or prune many images in one call, with failures isolated per job.

```elixir
# A list of {source, dest} jobs (or maps with :source/:dest/:opts):
{:ok, results} =
  Stevedore.sync([
    {"docker://alpine:3.20", "oci:./mirror/alpine:3.20"},
    {"docker://debian:12",   "oci:./mirror/debian:12"}
  ])
#=> {:ok, [{job, {:ok, %{digest: _}}}, {job, {:error, _}}]}  (one result per job; one failure won't abort the rest)

:ok = Stevedore.delete("oci:./mirror/alpine:3.20")
```

The CLI wraps this with a spec file — see [recipe 11](#11-the-cli-mix-stevedore).

---

## 4. Build an image from a directory (no Dockerfile)

**Intent:** assemble an image from a filesystem tree — no build daemon, no Dockerfile. Stevedore
*assembles* images from layers + a config; it never **runs** build steps. The deterministic tar +
timestamp-free gzip make the result **reproducible** (same input → same digest).

```elixir
{:ok, image} = Stevedore.Build.from_dir("./rootfs", %{cmd: ["/bin/sh"]})

# A built %Image{} carries its blob bytes, so it's a valid copy *source* — publish it straight off:
{:ok, %{digest: _}} = Stevedore.copy(image, "docker://ghcr.io/me/app:1.0")
```

The crucial correctness point — kept straight for you — is **diff_id** (sha256 of the *uncompressed*
tar, in `rootfs.diff_ids`) vs the **layer descriptor digest** (sha256 of the *compressed* bytes, in
the manifest):

```elixir
image.layers                  #=> [%Stevedore.Descriptor{}]  (compressed digests)
image.config.rootfs_diff_ids  #=> [%Stevedore.Digest{}]      (uncompressed digests — different!)
```

---

## 5. Build from layer tarballs & append

**Intent:** build with full control over each layer's bytes, then stack more on top. Layers are
plain uncompressed tar binaries (see [`Archive`](#stevedore-archive-tar-compression) in the
appendix for assembling entries).

```elixir
entries = [
  %{name: "etc/", type: :directory, mode: 0o755, size: 0, linkname: nil, content: nil},
  %{name: "etc/app.conf", type: :regular, mode: 0o644, size: 2, linkname: nil, content: "hi"}
]

{:ok, image} =
  Stevedore.Build.image(
    [Stevedore.Archive.write!(entries)],
    %{entrypoint: ["/bin/app"], env: ["LANG=C.UTF-8"], working_dir: "/srv"},
    platform: "linux/amd64", format: :oci, compression: :gzip
  )

# Append a layer (adds one history entry), then publish the built image straight to a registry:
{:ok, image} = Stevedore.Build.append(image, Stevedore.Archive.write!(patch_entries))
{:ok, %{digest: _}} = Stevedore.copy(image, "docker://ghcr.io/me/app:1.0")
```

---

## 6. Modify an image (retag / relabel / rebase / flatten)

**Intent:** retag, rewrite config, annotate, rebase onto a new base, or flatten — recomputing all
dependent digests, without re-pulling unchanged layers. Every verb returns a new `%Image{}`.

```elixir
# Rewrite the runtime config (map merges labels, replaces the rest):
image = Stevedore.Mutate.config(image, %{entrypoint: ["/bin/app", "--prod"], user: "1000:1000"})
# ...or with a function over the parsed Config struct:
image = Stevedore.Mutate.config(image, fn cfg -> %{cfg | env: ["DEBUG=0" | cfg.env || []]} end)

image = Stevedore.Mutate.annotations(image, %{"org.opencontainers.image.source" => "https://example/repo"})
image = Stevedore.Mutate.retag(image, "1.0.1")     # sets the tag a later copy will use

# Rebase: swap the base layers for a new base, keeping the app layers on top.
# Verifies the image actually starts with old_base's layers (else {:error, :base_mismatch}):
{:ok, rebased} = Stevedore.Mutate.rebase(image, old_base, new_base)

# Flatten the whole stack into one layer (whiteout-aware):
{:ok, flat} = Stevedore.Mutate.flatten(image)
```

---

## 7. Analyze image contents (merged FS / diff / read / SBOM)

**Intent:** read what's inside an image **in memory, without root**, honoring whiteouts. Works on a
built/pulled `%Image{}` or a list of raw layer binaries (bottom→top).

```elixir
# The whiteout-aware effective filesystem (paths are normalized: no leading "/"):
{:ok, view} = Stevedore.Layer.merged_view(image)
view["etc/os-release"]
#=> %{path: "etc/os-release", type: :regular, mode: 420, size: 98, linkname: nil, from_layer: 2}

# A single layer's entries (a built image's descriptor needs opts[:image] to fetch the bytes;
# a raw/compressed binary is sniffed automatically):
{:ok, entries} = Stevedore.Layer.entries(hd(image.layers), image: image)
{:ok, entries} = Stevedore.Layer.entries(some_gzip_layer_binary)

# Diff two layers (added / modified / removed paths, ignoring whiteout markers):
{:ok, %{added: a, modified: m, removed: r}} = Stevedore.Layer.diff(layer_a_bin, layer_b_bin)

# Query and read files from the effective filesystem (leading "/" optional):
{:ok, nodes}   = Stevedore.Analyze.files(image, ~r{^usr/bin/})          # Regex or (path -> bool)
{:ok, release} = Stevedore.Analyze.read_file(image, "/etc/os-release")   #=> {:ok, bytes} | {:error, :enoent}

# Best-effort SBOM from well-known metadata files (heuristic, no scanner, no shelling out):
{:ok, sbom} = Stevedore.Analyze.sbom(image)
#=> {:ok, %{"os" => %{"NAME" => "Alpine Linux", ...} | nil,
#           "packages" => [%{"name" => "musl", "version" => "1.2.4", "type" => "apk"}, ...]}}
```

> **Analyzing a remote image:** pull each layer blob with `Stevedore.Registry.blob/3` and pass the
> binaries to `Stevedore.Layer.merged_view([blob1, blob2, ...])`, or `copy` it into an `oci:` layout
> first.

---

## 8. Sign, verify & attach referrers (OCI 1.1)

**Intent:** produce a cosign-compatible signature, verify against a default-deny policy, and attach
artifacts (signatures, SBOMs, scans) to an image. All crypto is native (`:public_key`); nothing
shells out to `cosign`/`gpg`/`openssl`.

```elixir
key = Stevedore.Sign.Sigstore.generate_key()   #=> %{private: <PEM>, public: <PEM>}

# Sign an image -> a cosign signature artifact (an %Image{} with the payload layer + signature
# annotation, a subject pointing at the image, and the sha256-<hex>.sig tag):
{:ok, signature} = Stevedore.Sign.sigstore(image, key)
signature.tag  #=> "sha256-<digest hex>.sig"

# A native detached signature over the manifest digest (DER bytes; not the GPG wire format):
{:ok, der} = Stevedore.Sign.simple(image, key)
```

**Verify against a policy (default-deny)** — an unknown key fails closed:

```elixir
{:ok, [_ | _]} = Stevedore.Verify.image(image, %{keys: [key.public]}, signatures: [signature])

{:error, %Stevedore.Verify.Error{reason: :no_valid_signature}} =
  Stevedore.Verify.image(image, %{keys: [other_pubkey]}, signatures: [signature])

# require: :all needs every policy key to have a valid signature (:any is the default):
{:ok, _} = Stevedore.Verify.image(image, %{keys: [k1.public, k2.public], require: :all}, signatures: sigs)
```

**Attach & list referrers** — publish artifacts attached to an image, then discover them:

```elixir
{:ok, {transport, _}} = Stevedore.Transport.Parse.parse("docker://ghcr.io/me/app:1.0")
subject_digest = image.manifest.digest

# Attach a signature artifact (or any %Image{}) — sets its subject and pushes it:
{:ok, _artifact_digest} = Stevedore.Referrers.attach(transport, subject_digest, signature)

# Attach an arbitrary artifact from raw bytes (e.g. an SBOM):
sbom = %{media_type: "application/spdx+json", data: spdx_json, artifact_type: "application/spdx+json"}
{:ok, _} = Stevedore.Referrers.attach(transport, subject_digest, sbom)

# List referrers (Referrers API, with the <algo>-<hex> tag-schema fallback):
{:ok, index} = Stevedore.Referrers.list(transport, subject_digest)
{:ok, referrers} = Stevedore.Manifest.manifests(index)   #=> descriptors carrying :artifact_type

# Verify by fetching signatures over the transport (no need to hold them yourself):
{:ok, _} = Stevedore.Verify.image(subject_digest, %{keys: [key.public]}, transport: transport)
```

---

## 9. Serve a writable `/v2` registry

**Intent:** run a real registry (push + pull) backed by a directory. Opt-in (`:plug`/`:bandit`);
nothing boots until you call `start_link/1`.

```elixir
{:ok, _pid} =
  Stevedore.start_link(
    store: "/var/lib/stevedore",     # filesystem root for the registry data
    port: 5000,
    # The authz seam: action is :pull | :push | :delete. Default allows pull, denies writes.
    authorize: fn _conn, action, _scope ->
      if action == :pull, do: :ok, else: {:error, :unauthorized}
    end
  )

# Now any client speaks to it. Push with Stevedore's own client and pull it back:
{:ok, _} = Stevedore.copy("oci:./alpine:3.20", "docker://localhost:5000/library/alpine:3.20", scheme: "http")
{:ok, _} = Stevedore.copy("docker://localhost:5000/library/alpine:3.20", "oci:./roundtrip:3.20", scheme: "http")
```

**Mount the API inside a host Plug router** (you supply the upload-session process and storage):

```elixir
# In your supervision tree:
{Stevedore.Server.Uploads, name: MyApp.Uploads}

# In your Plug.Router:
forward "/v2", to: Stevedore.Plug,
  init_opts: [store: "/var/lib/stevedore", uploads: MyApp.Uploads,
              authorize: fn _conn, _action, _scope -> :ok end]
```

The server implements the full pull/push surface (manifests, blobs, chunked upload sessions,
`_catalog`, `tags/list`, and the OCI 1.1 referrers endpoint built from stored `subject` fields).

---

## 10. Deploy a static, read-only registry

**Intent:** serve images from a dumb web server or object store — no registry process. `tree/3`
writes the `v2/...` layout and returns the per-manifest headers a static server can't infer.

```elixir
{:ok, headers} = Stevedore.Deploy.tree("docker://alpine:3.20", "./public", name: "library/alpine")
headers["/v2/library/alpine/manifests/3.20"]
#=> %{"Content-Type" => "application/vnd.oci.image.manifest.v1+json", "Docker-Content-Digest" => "sha256:…"}

# Emit a server config that adds those headers (Docker-Distribution-Api-Version, Content-Type,
# Docker-Content-Digest) and serves the tree at /v2/...:
{:ok, nginx} = Stevedore.Deploy.nginx_config("./public", port: 5000)
{:ok, caddy} = Stevedore.Deploy.caddy_config("./public")
File.write!("registry.nginx.conf", nginx)
```

---

## 11. The CLI (`mix stevedore.*`)

**Intent:** the same verbs from the shell — same transport-prefixed references, consistent errors,
non-zero exit on failure. Run `mix help stevedore.<task>` for full options.

```sh
# Copy / mirror
mix stevedore.copy docker://alpine:3.20 oci:./alpine:3.20
mix stevedore.copy docker://alpine:3.20 docker://ghcr.io/me/alpine:3.20 --all
mix stevedore.copy oci:./alpine:3.20 docker://ghcr.io/me/alpine:3.20 --format docker

# Inspect (default summary, or --raw for the manifest bytes)
mix stevedore.inspect docker://alpine:3.20
mix stevedore.inspect oci:./alpine:3.20 --raw

# List tags / delete
mix stevedore.list_tags docker://library/alpine
mix stevedore.delete oci:./alpine:3.20

# Bulk sync from a spec file ("SRC DST" per line; # comments)
mix stevedore.sync ./mirror.txt

# Sign / verify (PEM keys)
mix stevedore.sign   docker://ghcr.io/me/app:1.0 --key cosign.key
mix stevedore.verify docker://ghcr.io/me/app:1.0 --key cosign.pub

# Deploy a static registry and emit a server config
mix stevedore.deploy docker://alpine:3.20 ./public --name library/alpine --server nginx --config registry.nginx.conf
```

---

## 12. End-to-end: build → sign → serve → verify

**Intent:** tie it together — assemble an image, run a registry, push it, sign it, and verify it back.

```elixir
# 1. Build an image from a rootfs directory.
{:ok, image} = Stevedore.Build.from_dir("./rootfs", %{entrypoint: ["/bin/app"]})

# 2. Start a local registry (allow writes for this example).
{:ok, _} = Stevedore.start_link(store: "/tmp/registry", port: 5000,
                                authorize: fn _, _, _ -> :ok end)
ref = "docker://localhost:5000/me/app:1.0"

# 3. Push the built image.
{:ok, %{digest: digest}} = Stevedore.copy(image, ref, scheme: "http")

# 4. Sign it and attach the signature as a referrer.
key = Stevedore.Sign.Sigstore.generate_key()
{:ok, signature} = Stevedore.Sign.sigstore(image, key)
{:ok, {transport, _}} = Stevedore.Transport.Parse.parse(ref, scheme: "http")
{:ok, _} = Stevedore.Referrers.attach(transport, digest, signature)

# 5. Verify it, fetching the signature back over the registry.
{:ok, [_ | _]} = Stevedore.Verify.image(digest, %{keys: [key.public]}, transport: transport)

# 6. Inspect what's inside, and extract an SBOM.
{:ok, sbom} = Stevedore.Analyze.sbom(image)
```

---

## Core building blocks

The pure data types — no processes, no I/O. The recipes above lean on these; reach for them
directly when you're working below the high-level verbs.

### `Stevedore.Reference` — parse & normalize an image name

Turn a human image string into a normalized, addressable reference (applying the Docker Hub
defaults everyone relies on).

```elixir
{:ok, ref} = Stevedore.Reference.parse("alpine:3.20")
ref.registry    #=> "registry-1.docker.io"   # bare names default to Docker Hub
ref.repository  #=> "library/alpine"          # single-segment repos get the library/ prefix
ref.tag         #=> "3.20"
ref.digest      #=> nil

# A pinned-by-digest reference (no default tag is applied):
{:ok, ref} = Stevedore.Reference.parse("ghcr.io/owner/app@sha256:e3b0c4…")
ref.registry           #=> "ghcr.io"
ref.digest.algorithm   #=> :sha256

# Round-trips to a canonical string that re-parses equal:
Stevedore.Reference.to_string(ref)  #=> "ghcr.io/owner/app@sha256:e3b0c4…"

# Caller mistakes are tagged, never raised:
Stevedore.Reference.parse("alpine@sha256:nothex")  #=> {:error, {:bad_input, _}}
```

### `Stevedore.Digest` — content addressing

Compute, verify, and render the `algorithm:hex` digests that identify every blob.

```elixir
d = Stevedore.Digest.compute("hello")          # default :sha256; pass :sha512 for the other
to_string(d)                                   #=> "sha256:2cf24dba5fb0…"  (String.Chars too)
Stevedore.Digest.verify("hello", d)            #=> :ok
Stevedore.Digest.verify("tampered", d)         #=> {:error, :digest_mismatch}
Stevedore.Digest.to_path(d)                    #=> "sha256/2cf24dba5fb0…"  (OCI blob layout)

# Parsing validates the algorithm allowlist and hex length/case — so a bad digest can never reach
# the on-disk Store and traverse out of the blob tree:
Stevedore.Digest.parse("sha256:../../etc")     #=> {:error, {:bad_input, _}}
```

### `Stevedore.MediaType` — classify media types

Decide what a descriptor points at, and how a layer is compressed, without hardcoding the (many)
OCI and Docker type strings.

```elixir
Stevedore.MediaType.manifest?("application/vnd.oci.image.manifest.v1+json")  #=> true
Stevedore.MediaType.index?("application/vnd.docker.distribution.manifest.list.v2+json")  #=> true
Stevedore.MediaType.gzip?("application/vnd.oci.image.layer.v1.tar+gzip")     #=> true
Stevedore.MediaType.zstd?("application/vnd.oci.image.layer.v1.tar+zstd")     #=> true

# Canonical constants + the Accept set used when fetching manifests:
Stevedore.MediaType.oci_manifest()        #=> "application/vnd.oci.image.manifest.v1+json"
Stevedore.MediaType.all_manifest_types()  #=> [all manifest + index types, OCI and Docker]
```

### `Stevedore.Descriptor` — a typed, digest-addressed pointer

The element a manifest uses to reference its config, layers, and (for an index) its per-platform
children.

```elixir
{:ok, desc} =
  Stevedore.Descriptor.from_json_full(%{
    "mediaType" => "application/vnd.oci.image.manifest.v1+json",
    "digest" => "sha256:e3b0c4…",
    "size" => 7,
    "platform" => %{"os" => "linux", "architecture" => "arm64", "variant" => "v8"}
  })

desc.platform  #=> %{os: "linux", architecture: "arm64", variant: "v8", os_version: nil}
Stevedore.Descriptor.to_json(desc)  #=> JSON-ready map; empty optional fields are omitted
```

### `Stevedore.Manifest` — image manifest *or* index

Parse manifest bytes once and ask structural questions; pick a platform from a multi-arch index.
`raw` is preserved so the digest is stable.

```elixir
{:ok, manifest} = Stevedore.Manifest.parse(raw_bytes, content_type_or_nil)

Stevedore.Manifest.kind(manifest)  #=> :manifest | :index  (sniffed if no media type)

# For a single image manifest:
{:ok, config_descriptor} = Stevedore.Manifest.config(manifest)
{:ok, layer_descriptors} = Stevedore.Manifest.layers(manifest)

# For a multi-arch index: list children, or select one by platform (defaults to the host):
{:ok, children} = Stevedore.Manifest.manifests(index)
{:ok, descriptor} = Stevedore.Manifest.select(index, os: "linux", architecture: "arm64")
{:error, :no_match} = Stevedore.Manifest.select(index, os: "linux", architecture: "ppc64le")

Stevedore.Manifest.host_platform()  #=> [os: "linux", architecture: "amd64"]  (BEAM arch mapped)
```

### `Stevedore.Config` — the image runtime config

Read entrypoint/cmd/env/user/workdir/labels and the `rootfs.diff_ids` (digests of the *uncompressed*
layers — distinct from the manifest's compressed layer digests).

```elixir
{:ok, config} = Stevedore.Config.parse(config_blob_bytes)
config.entrypoint        #=> ["/bin/app"] | nil
config.os                #=> "linux"
config.rootfs_diff_ids   #=> [%Stevedore.Digest{}, ...]
```

### `Stevedore.Archive` — tar & compression

Layers are tarballs; read and write them without shelling out to `tar`. gzip is native; zstd uses
the optional `:ezstd` NIF.

```elixir
entries = [
  %{name: "etc/", type: :directory, mode: 0o755, size: 0, linkname: nil, content: nil},
  %{name: "etc/hi", type: :regular, mode: 0o644, size: 2, linkname: nil, content: "hi"}
]

tar = Stevedore.Archive.write!(entries)         # ustar; raises on an unencodable entry
{:ok, ^entries} = Stevedore.Archive.read(tar)   # also reads GNU long-name + PAX from real images

# Compression:
gz = Stevedore.Archive.gzip(tar)                #=> binary (deterministic: no timestamp in header)
{:ok, ^tar} = Stevedore.Archive.gunzip(gz)

Stevedore.Archive.zstd_available?()             #=> false unless {:ezstd, "~> 1.1"} is added
# Stevedore.Archive.zstd(tar) / unzstd(zstd)    # raise a clear error when :ezstd is absent
```

### `Stevedore.Store` — content-addressed storage

On-disk transports persist blobs by digest through one interface, so backends are interchangeable.
Writes are atomic and digest-verified.

```elixir
digest = Stevedore.Digest.compute("blob-bytes")

# Filesystem store — config is a root path (or `[root: path]`); blobs land at <root>/blobs/<algo>/<hex>:
:ok = Stevedore.Store.Local.put("/var/lib/stevedore", digest, "blob-bytes")
{:ok, "blob-bytes"} = Stevedore.Store.Local.get("/var/lib/stevedore", digest)
true = Stevedore.Store.Local.exists?("/var/lib/stevedore", digest)
Stevedore.Store.Local.put("/var/lib/stevedore", digest, "WRONG")  #=> {:error, :digest_mismatch}

# In-memory store (tests / ephemeral) — config is the agent pid:
{:ok, store} = Stevedore.Store.Memory.start_link([])
:ok = Stevedore.Store.Memory.put(store, digest, "blob-bytes")
Stevedore.Store.Memory.local_path(store, digest)  #=> :unsupported  (no on-disk path)
```
