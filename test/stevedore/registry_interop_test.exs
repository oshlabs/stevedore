defmodule Stevedore.RegistryInteropTest do
  @moduledoc """
  Strategy 2 — exercise the `Stevedore.Registry` / `Stevedore.copy` **client** against two real
  registry servers that diverge on edge cases, so registry-specific client bugs surface:

    * **`registry:2`** (CNCF distribution) — the reference implementation. No native Referrers API
      (`Docker-Distribution-Api-Version: registry/2.0`), so the client's tag-schema fallback path
      is what's under test there.
    * **`zot`** (`ghcr.io/project-zot/zot-linux-amd64`) — a strict, OCI-native registry.

  Running registry *containers* in CI is a test-time dependency, not a runtime one — Stevedore
  itself never shells out to a daemon. Tag: `:external`. Bring the servers up first:

      docker compose -f docker-compose.test.yml up -d
      mix test --include external
      docker compose -f docker-compose.test.yml down

  Each case runs against **both** registries via a `for` comprehension. When a registry isn't
  reachable, its cases are *skipped* (not failed) — see `Stevedore.TestTools.registry_test/3`.

  Source images are built locally (fast, hermetic) except the digest-preservation round-trip, which
  pulls a digest-pinned public image (`Stevedore.Fixtures`) and pushes it to the local server — the
  real-world copy this whole step exists to protect.

  Spec: [distribution-spec](https://github.com/opencontainers/distribution-spec/blob/main/spec.md)
  (push/pull, cross-repo blob mount, tag list pagination, Referrers API, error codes).
  """
  use ExUnit.Case, async: false

  import Stevedore.TestTools, only: [registry_test: 3]

  alias Stevedore.{
    Archive,
    Build,
    Digest,
    Fixtures,
    Image,
    Manifest,
    Reference,
    Referrers,
    Registry
  }

  alias Stevedore.Transport

  @moduletag :external

  @registries [
    {:registry2, System.get_env("STEVEDORE_REGISTRY2_URL", "http://localhost:5000")},
    {:zot, System.get_env("STEVEDORE_ZOT_URL", "http://localhost:5001")}
  ]

  for {key, url} <- @registries do
    describe "#{key}" do
      @describetag registry: key

      # --- round-trip: digest preservation across a real public -> local copy ---

      registry_test "round-trips a digest-pinned public image with a stable manifest digest",
                    url do
        # The digest-preserving guarantee: copy a pinned upstream image into the local registry and
        # pull it back; the manifest digest must be byte-stable end to end (no re-encoding).
        repo = repo("roundtrip")
        dst = {transport(unquote(url), repo), "v1"}

        # The pinned source is a multi-arch index; the default copy writes the host-platform child
        # as a plain manifest at the tag (skopeo's default), so the stable digest is that child's.
        {:ok, child_digest} = host_child_digest(Fixtures.image("busybox:1.36"))

        assert {:ok, %{digest: pushed}} =
                 Stevedore.copy("docker://#{Fixtures.image("busybox:1.36")}", dst)

        assert pushed == child_digest

        assert {:ok, fetched} =
                 Registry.manifest(ref(unquote(url), repo, "v1"), ropts(unquote(url)))

        assert fetched.digest == child_digest
        # The server's Docker-Content-Digest agrees with a digest over the bytes it returned.
        assert fetched.digest == Digest.compute(fetched.raw)
      end

      # --- blob-skip: a second push HEADs blobs already present (has_blob? 200) ---

      registry_test "skips already-present blobs on a second push (HEAD 200 path)", url do
        image = built_image("blob-skip")
        repo = repo("blobskip")
        t = transport(unquote(url), repo)

        assert {:ok, %{digest: d1}} = Stevedore.copy(image, {t, "v1"})
        assert d1 == Image.digest(image)

        # After the first push the server reports every blob present — the HEAD-200 branch the
        # second push takes instead of re-uploading.
        assert Enum.all?(blob_digests(image), fn d ->
                 Registry.has_blob?(ref(unquote(url), repo, nil), d, ropts(unquote(url)))
               end)

        # Second push (a fresh tag, same content) still succeeds with the identical digest.
        assert {:ok, %{digest: d2}} = Stevedore.copy(image, {t, "v2"})
        assert d2 == Image.digest(image)
      end

      # --- cross-repo mount: registry -> registry on the same host ---

      registry_test "mounts blobs cross-repo on a same-host copy", url do
        # distribution-spec, "Mounting a blob from another repository":
        # POST .../blobs/uploads/?mount=<digest>&from=<repo>. registry:2 and zot differ on whether
        # they honour the mount; either way the copy must end with B holding every blob.
        image = built_image("mount")
        repo_a = repo("mount-a")
        repo_b = repo("mount-b")

        assert {:ok, _} = Stevedore.copy(image, {transport(unquote(url), repo_a), "v1"})

        assert {:ok, %{digest: d}} =
                 Stevedore.copy(
                   {transport(unquote(url), repo_a), "v1"},
                   {transport(unquote(url), repo_b), "v1"}
                 )

        assert d == Image.digest(image)

        assert Enum.all?(blob_digests(image), fn dig ->
                 Registry.has_blob?(ref(unquote(url), repo_b, nil), dig, ropts(unquote(url)))
               end)

        # The mount primitive itself: a direct cross-repo mount returns :ok (honoured) or
        # :not_mounted (declined) — both spec-legal — but never errors, and leaves the blob present.
        [blob | _] = blob_digests(image)

        result =
          Registry.mount_blob(
            ref(unquote(url), repo_b, nil),
            blob,
            repo_a,
            ropts(unquote(url))
          )

        assert result in [:ok, :not_mounted]
        assert Registry.has_blob?(ref(unquote(url), repo_b, nil), blob, ropts(unquote(url)))
      end

      # --- tag listing across many tags ---

      registry_test "lists every pushed tag", url do
        # distribution-spec, "Listing Image Tags": GET .../tags/list, following the RFC 8288 `Link`
        # header when the server paginates. We assert completeness over a tag count past the common
        # default page size; the Link-following branch runs whenever the server chooses to paginate.
        image = built_image("tags")
        repo = repo("tags")
        t = transport(unquote(url), repo)
        tags = for n <- 1..12, do: "v#{n}"

        Enum.each(tags, fn tag -> assert {:ok, _} = Stevedore.copy(image, {t, tag}) end)

        assert {:ok, listed} =
                 Stevedore.list_tags(ref(unquote(url), repo, nil), ropts(unquote(url)))

        assert MapSet.subset?(MapSet.new(tags), MapSet.new(listed))
      end

      # --- referrers (OCI 1.1 subject) ---

      registry_test "attaches a referrer and (where the API exists) lists it back", url do
        # image-spec `subject` + distribution-spec Referrers API. zot serves referrers natively;
        # registry:2 has no API (`Docker-Distribution-Api-Version: registry/2.0`).
        image = built_image("referrers")
        repo = repo("referrers")
        t = transport(unquote(url), repo)

        assert {:ok, %{digest: subject}} = Stevedore.copy(image, {t, "v1"})

        artifact = %{
          media_type: "application/vnd.stevedore.test.referrer",
          data: "referrer payload",
          artifact_type: "application/vnd.stevedore.test.referrer"
        }

        # `attach` always pushes the artifact manifest (with its `subject`); it is therefore
        # fetchable by its own digest regardless of how the registry indexes referrers.
        assert {:ok, referrer_digest} = Referrers.attach(t, subject, artifact)

        assert {:ok, _} =
                 Registry.manifest(ref(unquote(url), repo, referrer_digest), ropts(unquote(url)))

        assert {:ok, index} = Referrers.list(t, subject)
        {:ok, descriptors} = Manifest.manifests(index)
        listed = Enum.map(descriptors, & &1.digest)

        if referrers_api?(unquote(url), repo, subject) do
          # Native Referrers API (zot): the server records the `subject` link and lists it.
          assert referrer_digest in listed
        else
          # KNOWN GAP — DELIBERATELY NOT FIXED (decision 2026-06-06). On a registry WITHOUT the
          # Referrers API (registry:2, `Docker-Distribution-Api-Version: registry/2.0`) the OCI spec
          # has the *client* simulate the API via the tag-schema fallback: store/maintain an index
          # of referrers at the tag `<algo>-<hex>` of the subject digest. Stevedore implements only
          # the READ half of that fallback (`Registry.referrers_fallback/3` GETs that tag); the
          # WRITE half is missing — `Referrers.attach/4` pushes the artifact manifest with its
          # `subject` but never creates/updates the `<algo>-<hex>` index. So here the artifact is
          # pushed and fetchable by its own digest (asserted above), yet undiscoverable via list/3.
          #
          # Why we're leaving it: the gap only affects registries lacking the native API — in
          # practice legacy registry:2 / old self-hosted distribution. Every modern target (zot,
          # GHCR, Docker Hub, ECR, GAR, Harbor, distribution v3.0) has the API and already works.
          # The fix is moderate-effort, behaviour-changing, and incomplete by nature:
          #   1. `attach` would need the manifest-PUT response to know if the server recorded the
          #      subject (the `OCI-Subject` header), but it currently goes through `Stevedore.copy`,
          #      which returns only the digest and drops response headers — so the fix means new
          #      copy/transport plumbing or a separate referrers push path + capability probe.
          #   2. Maintaining the index is a non-atomic read-modify-write: concurrent attaches to the
          #      same subject can clobber each other (a lost update). This race is inherent to the
          #      tag-schema fallback — it's the very reason the native API exists.
          #   3. It's only half a story without a referrer-*delete* verb (which Stevedore lacks) to
          #      rewrite the index on removal.
          # Net: real cost and a built-in race for a shrinking legacy audience. Deferred until a
          # user actually needs a no-API registry. Documented as a known limitation in
          # docs/TESTING.md.
          #
          # This `refute` is a TRIPWIRE, not an endorsement of the current behaviour: if the write
          # side is ever implemented, the referrer will start appearing here and this assertion will
          # fail — forcing whoever does the fix to revisit this branch and turn it into an `assert`.
          refute referrer_digest in listed
        end
      end

      # --- delete ---

      registry_test "deletes a manifest so a later fetch 404s", url do
        # distribution-spec, "Deleting Manifests": DELETE .../manifests/<digest>. Both servers have
        # deletion enabled in docker-compose.test.yml; deletion is addressed by digest.
        image = built_image("delete")
        repo = repo("delete")
        t = transport(unquote(url), repo)

        assert {:ok, %{digest: digest}} = Stevedore.copy(image, {t, "v1"})
        assert {:ok, _} = Registry.manifest(ref(unquote(url), repo, "v1"), ropts(unquote(url)))

        assert :ok = Stevedore.delete({t, Digest.to_string(digest)})

        assert {:error, %Registry.Error{status: 404}} =
                 Registry.manifest(ref(unquote(url), repo, digest), ropts(unquote(url)))
      end

      # --- multi-arch index ---

      registry_test "round-trips a multi-arch index with all children and a stable digest", url do
        {index_raw, children} = built_index(["amd64", "arm64"])
        repo = repo("index")
        layout = seed_layout(index_raw, children)
        index_digest = Digest.compute(index_raw)

        assert {:ok, %{digest: pushed}} =
                 Stevedore.copy({layout, "v1"}, {transport(unquote(url), repo), "v1"}, all: true)

        assert pushed == index_digest

        assert {:ok, fetched} =
                 Registry.manifest(ref(unquote(url), repo, "v1"), ropts(unquote(url)))

        assert fetched.digest == index_digest

        {:ok, manifest} = Manifest.parse(fetched.raw, fetched.media_type)
        {:ok, descriptors} = Manifest.manifests(manifest)

        # Every child manifest is fetchable by digest from the pushed index.
        assert Enum.all?(descriptors, fn desc ->
                 match?(
                   {:ok, _},
                   Registry.manifest(ref(unquote(url), repo, desc.digest), ropts(unquote(url)))
                 )
               end)
      end

      # --- error envelopes ---

      registry_test "maps a missing-manifest 404 to a Registry.Error", url do
        # distribution-spec error codes: a GET for an unknown manifest yields the JSON error
        # envelope, which the client surfaces as {:error, %Registry.Error{status: 404}}.
        assert {:error, %Registry.Error{status: 404} = error} =
                 Registry.manifest(
                   ref(unquote(url), repo("missing"), "does-not-exist"),
                   ropts(unquote(url))
                 )

        assert error.registry == host(unquote(url))
      end
    end
  end

  # --- helpers ---

  # A small, deterministic single-layer image. The label keeps each test's content distinct so
  # their repos never share blobs by accident.
  defp built_image(label) do
    {:ok, image} = Build.image([Archive.gzip("#{label}-layer")], %{labels: %{"test" => label}})
    image
  end

  # A two-child index plus the child images, for the multi-arch round-trip.
  defp built_index(arches) do
    children =
      Enum.map(arches, fn arch ->
        {:ok, image} =
          Build.image([Archive.gzip("#{arch}-layer")], %{}, platform: "linux/#{arch}")

        {arch, image}
      end)

    manifests =
      Enum.map(children, fn {arch, image} ->
        %{
          "mediaType" => image.manifest.media_type,
          "size" => byte_size(image.manifest.raw),
          "digest" => Digest.to_string(Image.digest(image)),
          "platform" => %{"os" => "linux", "architecture" => arch}
        }
      end)

    raw =
      JSON.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => Stevedore.MediaType.oci_index(),
        "manifests" => manifests
      })

    {raw, children}
  end

  # Seed a fresh OCI-layout directory with an index and its children, to copy from.
  defp seed_layout(index_raw, children) do
    dir = Path.join(System.tmp_dir!(), "stevedore-idx-#{System.unique_integer([:positive])}")
    layout = %Transport.OCILayout{path: dir}

    Enum.each(children, fn {_arch, image} ->
      Enum.each(image.blobs, fn {digest, bytes} ->
        :ok = Transport.OCILayout.put_blob(layout, digest!(digest), bytes)
      end)

      {:ok, _} =
        Transport.OCILayout.put_manifest(
          layout,
          nil,
          image.manifest.raw,
          image.manifest.media_type
        )
    end)

    {:ok, _} =
      Transport.OCILayout.put_manifest(layout, "v1", index_raw, Stevedore.MediaType.oci_index())

    layout
  end

  # The manifest digest the default copy of a (possibly multi-arch) pinned public image will write:
  # the host-platform child's digest for an index, or the image's own digest for a plain manifest.
  defp host_child_digest(pinned) do
    {:ok, ref} = Reference.parse(pinned)
    {:ok, fetched} = Registry.manifest(ref)
    {:ok, manifest} = Manifest.parse(fetched.raw, fetched.media_type)

    case Manifest.kind(manifest) do
      :index ->
        with {:ok, desc} <- Manifest.select(manifest), do: {:ok, desc.digest}

      :manifest ->
        {:ok, fetched.digest}
    end
  end

  defp blob_digests(%Image{} = image) do
    image.blobs |> Map.keys() |> Enum.map(&digest!/1)
  end

  defp digest!(string) do
    {:ok, digest} = Digest.parse(string)
    digest
  end

  # Whether the server implements the native Referrers API for `repo`/`subject` (200 from the
  # endpoint) versus relying on the tag-schema fallback (404). distribution-spec, "Listing
  # Referrers": a registry without the API returns 404 for `/v2/<name>/referrers/<digest>`.
  defp referrers_api?(url, repo, subject) do
    endpoint = "#{url}/v2/#{repo}/referrers/#{Digest.to_string(subject)}"

    case Req.get(endpoint, retry: false) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  defp transport(url, repo),
    do: %Transport.Registry{registry: host(url), repository: repo, opts: ropts(url)}

  defp ref(url, repo, nil), do: %Reference{registry: host(url), repository: repo}

  defp ref(url, repo, %Digest{} = digest),
    do: %Reference{registry: host(url), repository: repo, digest: digest}

  defp ref(url, repo, tag) when is_binary(tag),
    do: %Reference{registry: host(url), repository: repo, tag: tag}

  defp ropts(url), do: [scheme: URI.parse(url).scheme]

  defp host(url) do
    uri = URI.parse(url)
    "#{uri.host}:#{uri.port}"
  end

  # A unique repository per test so re-runs never collide with leftover state.
  defp repo(name), do: "stevedore-test/#{name}-#{System.unique_integer([:positive])}"
end
