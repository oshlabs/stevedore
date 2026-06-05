# Stevedore

A **library-first, daemonless OCI toolkit for Elixir** — everything you can do to a container
image *except run it*.

A stevedore is the dockworker who loads, unloads, stows, and inspects shipping containers, and
never sails the ship. That is the boundary this library draws: Stevedore handles OCI artifacts
**at rest** (as bytes) — fetch, inspect, copy, mirror, build, modify, analyze, sign, verify,
and serve images. *Running* them (namespaces, mounts, cgroups) is out of scope.

It draws its feature surface from [Skopeo](https://github.com/containers/skopeo) (copy,
inspect, sync, sign) and extends it with the [crane](https://github.com/google/go-containerregistry)/[oras](https://oras.land)
create-modify-analyze surface and an opt-in registry server — none of which needs a kernel,
root, or a container runtime.

## Status

Pre-1.0, under active development. See the phased roadmap below. The public API is not yet
stable.

## Design principles

- **Weightless by default.** Depending on Stevedore starts no processes and pulls no heavy
  deps. The HTTP client (`req`), server (`plug`/`bandit`), and zstd NIF are **optional**,
  opted into per mode.
- **Daemonless, no database.** Talks to registries and on-disk layouts directly; for on-disk
  transports the filesystem is the source of truth.
- **Native.** Crypto, digests, and archives use `:crypto`/`:public_key`/`:zlib`. It never
  shells out to `skopeo`, `cosign`, `openssl`, or `tar`.
- **Digest-preserving.** Manifests and blobs move as raw bytes, so content digests are stable
  end to end.

## Installation

Add `stevedore` to your dependencies in `mix.exs`:

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
{:req, "~> 0.5"}          # the docker:// registry client
# {:bandit, "~> 1.0"}    # the standalone /v2 registry server
```

## Roadmap

| Phase | Deliverable |
|---|---|
| 0 | Skeleton: `Reference`, `Digest`, `Archive`, media types, the `Store` seam, CI |
| 1 | Registry client (`docker://`): manifest/blob/token fetch, `inspect`, multi-arch select |
| 2 | `copy` primitive + transports (`oci:`, `oci-archive:`, `dir:`, `docker-archive:`, static) |
| 3 | Registry server: `Stevedore.Plug` (`/v2`) + standalone Bandit |
| 4 | Create/modify: `Build.*` (assemble/append) and `Mutate.*` (config/annotations/retag) |
| 5 | Analyze: layer tar entries, whiteout-aware merged view, diff, content scanning |
| 6 | Sign/verify/referrers: sigstore + simple signing, OCI 1.1 `subject`/Referrers API |
| 7 | CLI (`mix stevedore.*`) + deploy (static-tree generators) |

## Documentation

- **[docs/EXAMPLES.md](docs/EXAMPLES.md)** — a worked tour of the whole verb surface, by
  lifecycle (fetch, copy, build, mutate, analyze, sign, serve, deploy).
- **[docs/REFERENCES.md](docs/REFERENCES.md)** — the specs Stevedore implements, with the
  specific sections mapped to modules.

Every module carries a `@moduledoc` and every public function a `@doc` + `@spec` (with `iex>`
doctests where they clarify usage). API docs are generated with
[ExDoc](https://github.com/elixir-lang/ex_doc) and, once published, will be available at
<https://hexdocs.pm/stevedore>.

## License

TODO
