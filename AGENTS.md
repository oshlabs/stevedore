This is `stevedore`, an Elixir project.

## About Stevedore

Stevedore is a **library-first, daemonless OCI toolkit for Elixir** — everything you can do
to a container image *except run it*. It operates on OCI artifacts **at rest** (as bytes):
fetch, inspect, copy, mirror, build, modify, analyze, sign, verify, and serve images. Running
them (namespaces, mounts, cgroups, isolation) is *in motion* and explicitly out of scope — that
belongs to the consumer (e.g. Tank, a separate orchestrator). It takes its feature inspiration
from Skopeo, and extends it with the crane/oras create-modify-analyze surface and a registry
server.

### Invariants that shape the code

- **Library-first, weightless.** Depending on Stevedore starts no processes and pulls no heavy
  deps. The HTTP client (`req`), the server (`plug`/`bandit`), and compression NIFs (zstd) are
  **optional deps**, opted into per mode. There is no `mod:` entry; the only thing that boots a
  process tree is an explicit `Stevedore.start_link/1` (the registry server).
- **Daemonless & no database.** Talk to registries and on-disk layouts directly. For on-disk
  transports the **filesystem (a `Store`) is the source of truth**.
- **Native crypto/archives.** Use `:crypto`, `:public_key`, `:zlib`. A NIF only where the BEAM
  genuinely can't reach a primitive (zstd). **Never shell out** to `skopeo`, `cosign`,
  `openssl`, `gpg`, or `tar` at runtime.
- **Digest-preserving.** Manifests and blobs move as **raw bytes**, never re-serialized — keep
  `raw` alongside decoded `json`; digests are computed over `raw`.
- **Pure core, pluggable shells.** Format logic is pure functions over structs. Storage,
  transports, serving, and CLI sit behind behaviours — the two seams are **`Stevedore.Store`**
  (blob/file I/O) and **`Stevedore.Transport`** (where images live). `copy` is the primitive
  everything composes from: transport → transport.
- **Elixir `~> 1.19`.** Use the built-in `JSON` module — **no `jason`**.

### Spec fidelity

When implementing a wire format, cite the authoritative section in a comment (name the section,
link a stable URL). Primary references:

- OCI Image Spec — <https://github.com/opencontainers/image-spec> (manifest, image-index,
  config, descriptor, layer media types, whiteouts).
- OCI Distribution Spec — <https://github.com/opencontainers/distribution-spec> (pull/push,
  blob uploads, tags list, referrers API).
- Docker Registry HTTP API v2 — <https://distribution.github.io/distribution/spec/api/>.
- Sigstore signature spec — <https://github.com/sigstore/cosign/blob/main/specs/SIGNATURE_SPEC.md>.

## Code style

- **Keep it simple.** Prefer the most obvious solution that works. Don't add abstraction, configurability, or generality until a second caller needs it.
- **Comment intent, not mechanics.** A comment explains *why*, or names a non-obvious constraint — never restate what the code plainly says.

      # BAD: restates the code
      # increment the counter
      count = count + 1

      # GOOD: explains why
      # Retry once before giving up: the upstream API returns a transient
      # 503 on cold start, but is reliably up by the second request.
      retry(request, max: 1)

- Keep comments concise — a sentence or two.
- When implementing an existing spec or wire format, cite the authoritative source in a comment — name the specific section, and link it where a stable URL exists.
- Match the style, naming, and comment density of the file you are editing.

## Documentation

- **Every module has a clear `@moduledoc`** (`@moduledoc false` only for genuinely internal
  modules) — what it is and the one or two things a reader needs to use it correctly.
- **Every public function has a clear `@doc`** preceding it — concise, stating what it does,
  with a `## Examples` `iex>` **doctest wherever one is useful and applicable** (deterministic,
  no network). Don't restate the spec or pad with the obvious.
- Keep the two committed guides current as the code grows:
  - `docs/EXAMPLES.md` — end-to-end, lifecycle-organized usage of the whole verb surface.
    Examples are phase-tagged; keep them truthful as phases land.
  - `docs/REFERENCES.md` — the specs implemented, with sections mapped to modules.
  - `docs/TESTING.md` — the test strategy: tag taxonomy, asymmetric interop, oracles, how to run
    each slice. Read it before adding integration/interop tests.
  All three are surfaced in the ExDoc build. `tmp/` (the plan + step docs) is git-ignored scaffolding.

## Elixir guidelines

- `@moduledoc`/`@doc`/`@spec` are mandatory as above. Document private functions only when intent isn't obvious.
- **Every public function has a `@spec`** — no exceptions. Add `@type`/`@typep` for non-trivial shapes.
- **Model domain data as structs**, not bare maps or loose tuples. Use `@enforce_keys` for required fields, declare a `@type t`, and tag function heads with `%Mod{}`.

      defmodule Stevedore.Thing do
        @enforce_keys [:name, :items]
        defstruct [:name, :items, status: :pending]

        @type t :: %__MODULE__{
                name: String.t(),
                items: [Stevedore.Item.t(), ...],
                status: :pending | :active | :done
              }
      end

- **Error handling — shape follows how much context the failure carries:**
  - **Context-rich failure → `%Stevedore.X.Error{}`** (one struct per subsystem; `defexception` + `message/1`; uniform rendering, plus honest extras only where non-nil). Errors from dependencies that bubble up are passed through as-is — don't re-wrap without adding context.
  - **Context-free condition → a bare atom** (`{:error, :not_found}`), like stdlib `File` / `:gen_tcp`.
  - **Caller input mistake → a tagged tuple** `{:error, {:bad_input, reason}}`. Do **not** `raise` for these — keep them in the `{:ok, _} | {:error, _}` world for `with` pipelines.
- **Never** nest multiple modules in one file — risks cyclic dependencies and compilation errors.
- Don't use `String.to_atom/1` on external input — memory-leak risk.

## Mix guidelines

- **Always run `mix format` before a git commit.**

## Test guidelines

- **Use `start_supervised!/1`** to start processes — it guarantees cleanup between tests.
- **Avoid** `Process.sleep/1` and `Process.alive?/1`:
  - To wait for a process to finish, use `Process.monitor/1` and assert the DOWN message:

        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  - To synchronize before the next call, use `_ = :sys.get_state(pid)`.
