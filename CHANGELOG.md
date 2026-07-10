# Changelog

All notable changes to Stevedore are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`Stevedore.Testing`** — test-support helpers for this library's and dependents' suites: a
  hermetic local registry (`start_registry!/1`), deterministic in-memory images
  (`synthetic_image/1`), and `push!/3` — real push/pull mechanics with zero external network.
- **`Stevedore.Build.index/2` / `Stevedore.Index`** — assemble a multi-arch OCI image index
  (or Docker manifest list) from per-platform built images; the result is a `Stevedore.copy/3`
  source like any image, so a built index can be pushed whole (`all: true`) or per platform.
- **`Stevedore.Testing.runnable_image/1`** — a synthetic image whose contents actually *run*:
  **`deckhand`**, a ~19 KB statically linked, libc-free container-diagnostics binary (built
  from `priv/deckhand/` with a pinned Zig; builds are byte-reproducible and CI rebuilds and
  byte-diffs the checked-in blobs) layered at `/bin/deckhand` — so dependents'
  runtime/exec/reconciler tests need no distro images. It is an event-printing REPL (console
  resizes via SIGWINCH, signal delivery, HTTP hits, graceful TERM/INT exit — it runs until
  signaled, so it doubles as the keepalive process) plus a GET-only web server on
  `0.0.0.0`/`::` whose URL space mirrors the command set — `/env`, `/id`, `/hostname`,
  `/uname`, `/ifaces`, `/mounts`, `/cat/PATH`, `/ls/PATH`, `/find/PATH` (rootfs probes),
  `/ping/HOST` (ICMP, IPv4/IPv6, DNS names via a built-in stub resolver), `/ping6/HOST`
  (forced IPv6, AAAA only — proves the v6 path to a dual-stack host), `/resolve/NAME` — so tests can inspect
  the container's view of its world from outside. `exit` is REPL-only; remote peers cannot
  kill the container. A second instance in the same netns finds the port taken and degrades
  gracefully to REPL-only, so tests can exec another copy inside a running container.
  `platforms: :all` returns both linux/amd64 and linux/arm64 under a real OCI index for
  hermetic index-resolution tests.

## [0.2.0] - 2026-06-06

### Added

- **`Stevedore.Auth.Cache`** — an opt-in, in-process bearer-token cache. Pass it as the
  `:token_cache` option to `Stevedore.Registry` to reuse a token across a pull's manifest + blob
  fetches: the first request earns the token, the rest send it preemptively, skipping the `401`
  and the token-endpoint round-trip. A stale token still falls back to a fresh handshake, so the
  cache changes request count, never results. Off by default — nothing starts unless you start a
  cache, preserving the weightless-by-default invariant.

## [0.1.0] - 2026-06-06

First public release — the full at-rest OCI toolkit. Pre-1.0: the public API may still shift.

### Added

- **Fetch & inspect** — a `docker://` Distribution v2 client (`Stevedore.Registry`) with
  bearer-token auth (`Stevedore.Auth`), multi-arch select, digest-verified blobs, and
  CDN-redirect token-leak protection.
- **Copy** — one digest-preserving primitive (`Stevedore.copy/3`) across transports:
  `docker://`, `oci:`, `oci-archive:`, `docker-archive:`, `dir:`, and `static:`, with
  multi-arch/platform/format control, blob-skip, and cross-repo mount. Plus `Stevedore.sync/2`
  for declarative mirror jobs.
- **Build & modify** — assemble images from layers or a directory (`Stevedore.Build`); append,
  retag, rewrite config, annotate, rebase, and flatten (`Stevedore.Mutate`) — all digest-correct.
- **Analyze** — whiteout-aware merged filesystem, per-layer entries, diffs, file reads, and a
  best-effort SBOM (`Stevedore.Analyze`).
- **Sign & verify** — cosign-compatible signatures with native ECDSA (`Stevedore.Sign`),
  policy verification (`Stevedore.Verify`), and OCI 1.1 `subject`/Referrers (`Stevedore.Referrers`).
- **Serve & deploy** — a writable `/v2` registry server on Bandit (`Stevedore.Server`,
  `Stevedore.Plug`), or a static tree plus generated nginx/caddy config (`Stevedore.Deploy`).
- **CLI** — `mix stevedore.{copy,delete,deploy,inspect,list_tags,sign,sync,verify}`.
- **Optional, weightless by default** — adding `:stevedore` starts no processes and pulls no
  heavy deps. The HTTP client (`:req`), the registry server (`:plug`/`:bandit`), and
  zstd layers (`:ezstd`) are opt-in per mode.

[0.1.0]: https://github.com/oshlabs/stevedore/releases/tag/v0.1.0
