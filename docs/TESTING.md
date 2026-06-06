# Testing & interop

How Stevedore is tested, why the suite is shaped the way it is, and how to run each slice. This
guide is for **contributors** (what to run, what each layer proves) and for anyone **evaluating**
the library (how thoroughly its claims are verified).

The short version: `mix test` is fast, hermetic, and offline; everything that touches a network, a
real registry, an external binary, or a Go toolchain is gated behind an ExUnit tag and **excluded by
default**. A machine missing a tool still gets a clean run — the affected cases *skip*, they never
fail.

## The core idea: asymmetric interop

Stevedore is *both* a registry client and a registry server, *both* a producer and a consumer of OCI
artifacts. That symmetry is a trap for testing: if you push with Stevedore and pull with Stevedore,
a **shared encoding bug passes in both directions** and the test stays green. Round-tripping against
yourself proves consistency, not correctness.

So the high-value tests are **asymmetric — produce with one tool, consume with another:**

- Write an `oci:` layout with Stevedore, load it with `skopeo` / `crane` / `podman`; and read
  layouts those tools wrote.
- Build an image with `Stevedore.Build`, push it, then **actually `podman run` it** — running the
  *output* is the only true test that the layers and config are well-formed.
- Sign with Stevedore, verify with real `cosign`; sign with `cosign`, verify with Stevedore.
- Compare `Stevedore.Analyze`'s merged filesystem against `crane export` for the same image.

Those external tools are **oracles**: independent implementations, written to the same specs, free of
our blind spots. Self round-tripping (Stevedore → Stevedore) is a fallback, not the goal.

> **The runtime invariant still holds.** Stevedore never shells out to `skopeo`, `cosign`, `crane`,
> `tar`, or `openssl` *at runtime* (see [AGENTS.md](AGENTS.md)). These tools appear **only in
> `test/`**, as oracles — never in `lib/`. Likewise, running a `registry:2` / `zot` container in CI
> is a *test-time* dependency, not a runtime one: the library itself talks to registries and on-disk
> layouts directly.

## The testing surface

Each surface is tested against a third-party oracle chosen to expose bugs a self-test can't:

| Surface | Exposed by | Strategy | Oracle |
| --- | --- | --- | --- |
| Registry **server** | `Stevedore.start_link/1`, `Stevedore.Plug` | Run the official conformance suite against it | OCI distribution-spec `conformance.test` |
| **Client / copy** | `Stevedore.copy/3`, `sync/2`, `inspect/2`, `Stevedore.Registry` | Run against real registries | `registry:2`, `zot` |
| **Build / mutate** | `Stevedore.Build`, `Stevedore.Mutate` | Build → push → **run** the output | `podman` / `docker` |
| **Sign / verify** | `Stevedore.Sign`, `Stevedore.Verify` | Cross-sign and cross-verify (both directions) | `cosign` |
| **Analyze** | `Stevedore.Analyze`, `Stevedore.Layer` | Compare merged-fs / whiteout handling | `crane export`, `podman export` |
| **Format validity** | every JSON we emit | Schema-validate the bytes | image-spec JSON schemas |
| **Transports** | `oci:`, `oci-archive:`, `docker-archive:`, `dir:`, `static:` | Layout round-trip across tools | `skopeo`, `crane` |

## Tags & how to run each slice

The default exclude list lives in `test/test_helper.exs`:

```elixir
ExUnit.configure(exclude: [:external, :conformance, :interop])
```

```bash
mix test                          # fast, hermetic, offline — the PR gate (unit + schema validity)
mix test --include external       # client vs real registry:2 + zot (needs the compose stack up)
mix test --include conformance    # boots the server + runs the OCI distribution-spec suite (needs Go)
mix test --include interop        # produce/consume vs skopeo/crane/cosign/podman/oras/regctl
```

The four layers, fastest first:

1. **`fast` (untagged, hermetic).** The pure core — formats, digests, parsing, the `Store`/copy
   logic — plus **format-validity** tests that schema-validate every manifest, index, config, and
   descriptor Stevedore emits against the upstream image-spec schemas (vendored under
   `test/support/schema/`). No network, no binaries. This is the required gate.

2. **`:external`.** The `docker://` client and `copy` against two real registries that diverge on
   edge cases (referrers fallback, cross-repo mount, error envelopes): **`registry:2`** (the CNCF
   reference implementation, no native Referrers API) and **`zot`** (strict, OCI-native). Bring them
   up first:

   ```bash
   docker compose -f docker-compose.test.yml up -d
   mix test --include external
   docker compose -f docker-compose.test.yml down
   ```

3. **`:conformance`.** The official OCI distribution-spec `conformance.test` (a Go/Ginkgo binary)
   run against a live `Stevedore.Server`, asserting zero failures across pull / push /
   content-discovery / content-management. The support module clones the pinned spec tag
   (`v1.1.0`) and `go test -c`s it, caching the binary under `_build/conformance/`. Needs a Go
   toolchain; skips cleanly without one. (Results can be self-submitted for the OCI conformance
   badge at <https://github.com/opencontainers/oci-conformance>.)

4. **`:interop`.** The asymmetric produce/consume matrix above, against the external oracle tools.

## Tooling

The interop and conformance slices drive real binaries. **Exact versions are pinned in CI**
(`.github/workflows/ci.yml`) so a green run today is green next month; that workflow is the source of
truth. The oracles:

| Tool | Role |
| --- | --- |
| `docker` / `podman` | run `registry:2`/`zot`; `run` built images |
| `skopeo` | layout/archive round-trip, copy |
| `crane` | layout round-trip, `crane export` for analyze |
| `cosign` | sign/verify cross-check |
| `go` | build the conformance binary |
| `oras` / `regctl` | artifact/referrers fixtures & checks |

**Skip, don't fail, when a tool is absent.** `Stevedore.TestTools` provides `tool_test/3` (skips with
a clear "missing tools: …" reason when a binary isn't found) and `registry_test/3` (skips when the
registry isn't reachable). `oras` and `regctl` are usually `go install`ed into `~/go/bin`, which may
not be on `PATH`; `TestTools.find/1` falls back to `~/go/bin`, so the suite works whether or not your
shell rc exports it.

## What the suite has caught

The point of asymmetric interop is to find bugs unit tests structurally can't. It has:

- **3 registry-server bugs** (distribution-spec conformance, fixed): out-of-order chunked-blob
  `PATCH` now returns `416`; a manifest `PUT` with a `subject` now echoes the `OCI-Subject` response
  header; the referrers index now propagates per-referrer `annotations`.
- Confirmed **cosign interop both ways** with real `cosign` — Stevedore's signatures verify under
  `cosign verify`, and `cosign`-made signatures verify under `Stevedore.Verify` (wrong key fails
  closed).
- Confirmed **built images run** under both `podman` and `docker` with the expected `Env` /
  `WorkingDir` / `User` observed inside the running container.

## Known limitations (current scope)

Documented deliberately so the boundaries are honest:

- **Signing format.** Stevedore implements cosign's **legacy simple-signing** format (the
  `sha256-<hex>.sig` tag, `dev.cosignproject.cosign/signature` annotation). cosign 3.x's *default*
  `sign` now emits a Sigstore **DSSE bundle** as an OCI referrer, which `Stevedore.Verify` does not
  read yet. `cosign verify` remains backward-compatible with our signatures. (The interop test pins
  the legacy format with `--registry-referrers-mode=legacy` and friends.)
- **Referrers on no-API registries.** On a registry **without** the Referrers API (e.g. `registry:2`),
  `Referrers.attach/4` pushes the artifact with its `subject` but does not yet maintain the
  `<algo>-<hex>` tag-schema *fallback index* that `Referrers.list/3` reads — so the referrer is
  undiscoverable there. Modern targets with the native API (zot, GHCR, Docker Hub, ECR, GAR, Harbor,
  distribution v3) work. The `:external` suite asserts strong behavior on zot and carries a tripwire
  on `registry:2` that flips when this lands.

## CI

Four jobs match the tag taxonomy, fastest first (see `.github/workflows/ci.yml`):

| Job | Command | Setup |
| --- | --- | --- |
| `fast` | `mix test` (+ format, `--warnings-as-errors`, dialyzer) | beam only — required PR gate |
| `external` | `mix test --include external --only external` | `registry:2` + `zot` via compose |
| `conformance` | `mix test --include conformance --only conformance` | Go toolchain |
| `interop` | `mix test --include interop --only interop` | skopeo, crane, cosign, podman, oras, regctl |

## References

- OCI Distribution Spec + conformance — <https://github.com/opencontainers/distribution-spec>
- OCI Image Spec (+ `schema/`) — <https://github.com/opencontainers/image-spec>
- cosign `SIGNATURE_SPEC` — <https://github.com/sigstore/cosign/blob/main/specs/SIGNATURE_SPEC.md>
- `registry:2` (distribution) — <https://github.com/distribution/distribution> ·
  `zot` — <https://github.com/project-zot/zot>
- `skopeo` — <https://github.com/containers/skopeo> ·
  `crane` — <https://github.com/google/go-containerregistry> ·
  `cosign` — <https://github.com/sigstore/cosign>

See also [REFERENCES.md](REFERENCES.md) (specs mapped to modules) and [AGENTS.md](AGENTS.md) (design
boundary and conventions).
