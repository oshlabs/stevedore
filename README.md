# Stevedore

**A library-first, daemonless OCI toolkit for Elixir — everything you can do to a container image
*except run it*.**

A stevedore is the dockworker who loads, unloads, stows, and inspects shipping containers, and
never sails the ship. That is exactly the line this library draws:

> Stevedore handles OCI artifacts **at rest** — as bytes. Running them (namespaces, mounts, cgroups)
> is *in motion*, and out of scope.

Everything Stevedore does operates on images-as-data: **fetch, inspect, copy, mirror, build, modify,
analyze, sign, verify, and serve.** None of it needs a kernel, root, or a container runtime — which
is the whole point. It stays portable and embeddable by any application that deals with images,
whether or not that application can (or wants to) run them.

It takes its feature surface from [Skopeo](https://github.com/containers/skopeo) (copy, inspect,
sync, sign) and extends it with the create/modify/analyze surface of
[crane](https://github.com/google/go-containerregistry) and [ORAS](https://oras.land), plus an
opt-in registry server.

## Status

Pre-1.0, under active development. The full at-rest toolkit (registry client, copy + transports,
registry server, build/mutate, analyze, sign/verify/referrers, CLI + deploy) is implemented and
tested; the public API may still shift before 1.0.

## A taste

```elixir
# Mirror a multi-arch image from one registry to another (digests preserved, blobs skipped/mounted):
Stevedore.copy("docker://alpine:3.20", "docker://ghcr.io/me/alpine:3.20", all: true)

# Build an image from a directory tree — declaratively, no Dockerfile, no `RUN`:
{:ok, image} = Stevedore.Build.from_dir("./rootfs", %{entrypoint: ["/bin/app"]})
Stevedore.copy(image, "oci:./out:1.0")

# Read what's inside, in memory and without root (whiteout-aware):
{:ok, sbom} = Stevedore.Analyze.sbom(image)

# Run a real /v2 registry — nothing starts until you ask:
Stevedore.start_link(store: "/var/lib/stevedore", port: 5000)
```

…or from the shell:

```sh
mix stevedore.copy docker://alpine:3.20 oci:./alpine:3.20
mix stevedore.inspect docker://alpine:3.20
mix stevedore.deploy docker://alpine:3.20 ./public --server nginx --config registry.conf
```

## Design principles

- **Weightless by default.** Adding `:stevedore` starts no processes and pulls no heavy
  dependencies. The HTTP client (`req`), the registry server (`plug`/`bandit`), and zstd
  (`ezstd`) are **optional** — you opt into them only for the modes you use.
- **Daemonless, no database.** It talks to registries and on-disk layouts directly; for on-disk
  transports the filesystem is the source of truth.
- **Native.** Crypto, digests, signing, and archives use `:crypto`/`:public_key`/`:zlib`. It never
  shells out to `skopeo`, `cosign`, `openssl`, `gpg`, or `tar`.
- **Digest-preserving.** Manifests and blobs move as raw bytes, so content digests stay stable end
  to end. Conversions that must re-serialize (e.g. OCI ↔ Docker v2s2) say so.
- **Pure core, pluggable shells.** Format logic is pure functions over structs; storage,
  transports, serving, and the CLI sit behind behaviours. `copy` is the primitive everything
  composes from: any transport → any transport.

## What it can do

| Area | Highlights |
|---|---|
| **Fetch** | `docker://` Distribution v2 client: bearer-token auth, multi-arch select, digest-verified blobs, CDN-redirect token-leak protection |
| **Copy** | one primitive across transports — `docker://`, `oci:`, `oci-archive:`, `docker-archive:`, `dir:`, `static:` — with multi-arch/platform/format control, blob-skip and cross-repo mount |
| **Build / modify** | assemble images from layers or a directory; append, retag, rewrite config, annotate, rebase, flatten — all digest-correct |
| **Analyze** | whiteout-aware merged filesystem, per-layer entries, diffs, file reads, best-effort SBOM |
| **Sign / verify** | cosign-compatible signatures (native ECDSA), policy verification, OCI 1.1 `subject`/Referrers |
| **Serve / deploy** | a writable `/v2` registry (Bandit), or a static tree + generated nginx/caddy config a dumb web server can host |

## Installation

Add `stevedore` to your dependencies:

```elixir
def deps do
  [
    {:stevedore, "~> 0.1"}
  ]
end
```

The base build is dependency-free. Opt into modes as needed:

```elixir
{:stevedore, "~> 0.1"},
{:req, "~> 0.5"},                 # the docker:// registry client
{:plug, "~> 1.16"},              # \
{:bandit, "~> 1.5"},             #  } the standalone /v2 registry server
{:ezstd, "~> 1.1"}              # zstd-compressed layers
```

Target Elixir is `~> 1.19` (uses the built-in `JSON` module — no `jason`).

## Documentation

- **[Cookbook](https://hexdocs.pm/stevedore/examples.html)** — task-oriented recipes (mirror, build
  from a directory, sign & verify, serve a registry, …), each a complete copy-paste block with its
  intent and expected result. Start here to *do* something.
- **[References](https://hexdocs.pm/stevedore/references.html)** — the OCI/Docker/sigstore
  specifications Stevedore implements, mapped section-by-section to the modules that implement them.
- **[Testing](https://hexdocs.pm/stevedore/testing.html)** — the test strategy: the hermetic core,
  the `:external`/`:conformance`/`:interop` tag taxonomy, external tools used as *oracles* (never in
  `lib/`), how to run each slice, and the CI job map.
- **[AGENTS.md](https://hexdocs.pm/stevedore/agents.html)** — the project's design boundary and
  coding conventions (start here to contribute).

Every module carries a `@moduledoc` and every public function a `@doc` + `@spec` (with `iex>`
doctests). API docs are generated with [ExDoc](https://github.com/elixir-lang/ex_doc) and, once
published, will be at <https://hexdocs.pm/stevedore>.

## Specifications

- [OCI Image Spec](https://github.com/opencontainers/image-spec) ·
  [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec) ·
  [Docker Registry HTTP API v2](https://distribution.github.io/distribution/spec/api/)

## License

[Apache License 2.0](https://github.com/oshlabs/stevedore/blob/main/LICENSE).

Stevedore draws directly on the design and conventions of the cloud-native container ecosystem —
**Skopeo**, **cosign**, **crane**, and **ORAS** — which are themselves Apache-2.0. Matching that
license keeps Stevedore compatible with the projects it learns from and interoperates with, and the
Apache license's explicit patent grant is the norm for OCI tooling. Copyright 2026 oshlabs.
