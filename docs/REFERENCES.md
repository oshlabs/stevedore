# References

The authoritative specifications and prior art Stevedore implements against. When implementing
a wire format, cite the specific section here (and in a code comment) — not just the repo.

## OCI specifications (primary)

### Image Spec — <https://github.com/opencontainers/image-spec>
The on-disk/on-wire format of images. Sections Stevedore implements:

- **`descriptor.md`** — the descriptor type (`mediaType`, `digest`, `size`, `urls`, `platform`,
  `annotations`, `artifactType`) and the **digest** grammar (`algorithm:hex`, sha256/sha512).
  → `Stevedore.Descriptor`, `Stevedore.Digest`.
- **`manifest.md`** — the image manifest; `config` + `layers` descriptors; the OCI 1.1
  **`subject`** and **`artifactType`** fields. → `Stevedore.Manifest`, `Stevedore.Referrers`.
- **`image-index.md`** — the multi-arch index (manifest list) and `platform` matching.
  → `Stevedore.Manifest` (`kind/1`, `select/2`).
- **`config.md`** — image config: `entrypoint`/`cmd`/`env`/`user`/`workingDir`, `rootfs.diff_ids`
  (digests of **uncompressed** layers — distinct from layer descriptor digests, which are over
  the **compressed** bytes), `history`. → `Stevedore.Config`, `Stevedore.Build`.
- **`layer.md`** — layer tar representation; **whiteouts** (`.wh.<name>`) and **opaque
  whiteouts** (`.wh..wh..opq`); change-set semantics. → `Stevedore.Layer.merged_view/2`.
- **`media-types.md`** — the OCI media-type strings and their relationships. → `Stevedore.MediaType`.
- **`image-layout.md`** — the `oci:` layout (`oci-layout` marker, `index.json`,
  `blobs/<algo>/<hex>`). → `Stevedore.Transport.OCILayout`, `Stevedore.Store.Local` path layout.
- **`annotations.md`** — pre-defined annotation keys. → `Stevedore.Mutate.annotations/2`.

### Distribution Spec — <https://github.com/opencontainers/distribution-spec>
The registry HTTP API. Sections Stevedore implements:

- **Pull** — `GET /v2/`, manifest fetch with `Accept` negotiation, `Docker-Content-Digest`,
  blob fetch. → `Stevedore.Registry`, `Stevedore.Transport.Registry`, `Stevedore.Plug`.
- **Push** — blob upload sessions (`POST`/`PATCH`/`PUT`, monolithic + chunked), cross-repo blob
  **mount** (`?mount=&from=`), manifest `PUT`. → `Stevedore.Transport.Registry`,
  `Stevedore.Server.Uploads`.
- **Content management** — `DELETE` manifests/blobs, `_catalog`, `tags/list` pagination
  (`n`/`last`, `Link`). → `Stevedore.list_tags/1`, `Stevedore.Plug`.
- **Referrers API** — `GET /v2/<name>/referrers/<digest>?artifactType=…` and the **tag-schema
  fallback** for registries without it. → `Stevedore.Referrers`.
- **Error codes** — the `{"errors":[{code,message,detail}]}` body and code set
  (`MANIFEST_UNKNOWN`, `BLOB_UNKNOWN`, `DIGEST_INVALID`, `NAME_UNKNOWN`, …). → `Stevedore.Plug`.

## Docker / Distribution (interop)

- **Docker Registry HTTP API v2** — <https://distribution.github.io/distribution/spec/api/>.
  The pre-OCI API Stevedore stays bug-compatible with.
- **Token authentication** — <https://distribution.github.io/distribution/spec/auth/token/>.
  The `Www-Authenticate: Bearer realm=…,service=…,scope=…` challenge/exchange.
  → `Stevedore.Auth`.
- **Docker image manifest v2 schema 2** (`application/vnd.docker.distribution.manifest.v2+json`)
  and **manifest list** — the `--format v2s2` conversion target. Legacy **schema 1** (`v2s1`) is
  read-only. → `Stevedore.Manifest`, `copy` format conversion.
- **`docker save`/`load` archive** — the `docker-archive:` `manifest.json` (`RepoTags`/`Config`/
  `Layers`) layout. → `Stevedore.Transport.Archive`.
- **`~/.docker/config.json`** — `auths` with base64 `auth`, and credential helpers.
  → `Stevedore.Auth.from_docker_config/1`.

## Transports & verbs (prior art)

- **Skopeo** — <https://github.com/containers/skopeo>. The verb/feature target
  (`copy`/`inspect`/`sync`/`sign`); `copy` is the primitive everything composes from.
- **containers-transports(5)** —
  <https://github.com/containers/image/blob/main/docs/containers-transports.5.md>. Transport
  reference syntax (`docker://`, `oci:`, `oci-archive:`, `docker-archive:`, `dir:`).
  → `Stevedore.Transport.Parse`.
- **crane** — <https://github.com/google/go-containerregistry/tree/main/cmd/crane>. The
  create/modify surface (`append`, `mutate`, `rebase`, `flatten`). → `Stevedore.Build`,
  `Stevedore.Mutate`.
- **ORAS / OCI artifacts** — <https://oras.land>. Arbitrary artifacts via `config` + blobs +
  `artifactType`, attached by `subject`. → `Stevedore.Referrers`.

## Signing

- **Cosign signature spec** —
  <https://github.com/sigstore/cosign/blob/main/specs/SIGNATURE_SPEC.md>. The
  `application/vnd.dev.cosign.simplesigning.v1+json` payload and the `…sig` tag/referrer layout.
  → `Stevedore.Sign.Sigstore`, `Stevedore.Verify`.
- **containers/image simple signing** — the GPG-style detached signature over a manifest.
  → `Stevedore.Sign.simple/3`.

## Format primitives

- **POSIX `pax`/ustar tar** — layer archive format (GNU long-name handling for real images).
  → `Stevedore.Archive`.
- **gzip** (RFC 1952) via Erlang `:zlib`; **zstd** (RFC 8878) via an optional NIF.
  → `Stevedore.Archive`, `Stevedore.Layer`.

> See `tmp/PLAN.md §11` for the same list in the design document, and each `tmp/STEP-n-*.md`
> for the per-phase section citations.
