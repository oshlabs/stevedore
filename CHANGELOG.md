# Changelog

All notable changes to Stevedore are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
