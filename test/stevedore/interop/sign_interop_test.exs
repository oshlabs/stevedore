defmodule Stevedore.Interop.SignInteropTest do
  @moduledoc """
  Strategy 3 (part 3 of 4) — **sign ↔ cosign, both directions**, the step's explicit priority. A
  signature is the one artifact where a subtle encoding choice (payload canonicalization, base64,
  the DER signature bytes, the `dev.cosignproject.cosign/signature` annotation, the media type, the
  `sha256-<hex>.sig` tag) breaks compat *silently* — a self round-trip would happily pass both
  directions of a shared bug. Only a cross-tool check against real `cosign` settles the
  cosign-compatibility claim in `Stevedore.Sign`'s `@moduledoc`.

  ## What we assert

    * **Stevedore signs → `cosign verify` accepts** — a plain image, an annotated image, and a
      multi-arch index digest. `Sign.sigstore/3` emits a signature artifact real cosign trusts.
    * **`cosign sign` → `Stevedore.Verify.image/3` accepts** — cosign's own signature satisfies our
      verifier under the matching public key.
    * **Wrong key fails closed** — a signature made by a *different* key is rejected (default-deny,
      the AGENTS.md guarantee worth proving against a real signature, not a synthetic one).
    * **Encoding cross-checks** — the annotation key, the payload media type, the `.sig` tag scheme,
      and the simple-signing `critical` payload subtree match byte-for-byte what cosign emits for the
      same digest.

  ## Keys & offline operation

  Two key bridges, one per direction:

    * Direction 1: a Stevedore keypair (`Sigstore.generate_key/0`) → its public PEM handed to
      `cosign verify --key`.
    * Direction 2: `cosign generate-key-pair` (password-less, `COSIGN_PASSWORD=`) → `cosign sign
      --key cosign.key`, and the plain `cosign.pub` PEM handed to `Stevedore.Verify`. cosign's
      private key is encrypted and Stevedore never reads it; only the public half crosses over.

  All cases are **keyed and offline** — no Fulcio/Rekor. cosign runs with `--tlog-upload=false`
  (sign) / `--insecure-ignore-tlog` (verify), `--allow-http-registry` (the compose `registry:2`
  speaks plain HTTP), and `--registry-referrers-mode=legacy` so signatures are discovered at the
  `sha256-<digest>.sig` tag both tools agree on, not the OCI 1.1 referrers API.

  Tag: `:interop`. Oracle: `cosign` 3.0.6 + the compose `registry:2`. Skips cleanly when `cosign`
  is absent or the registry is down. Run:

      docker compose -f docker-compose.test.yml up -d
      mix test --include interop test/stevedore/interop/sign_interop_test.exs

  Specs / tool docs:
    * cosign SIGNATURE_SPEC (simple-signing payload, signature annotation, `.sig` tag) —
      <https://github.com/sigstore/cosign/blob/main/specs/SIGNATURE_SPEC.md>
    * `cosign verify` / `cosign sign` —
      <https://github.com/sigstore/cosign/blob/main/doc/cosign_verify.md>,
      <https://github.com/sigstore/cosign/blob/main/doc/cosign_sign.md>
  """
  use ExUnit.Case, async: false

  import Stevedore.TestTools, only: [find: 1, available?: 1]

  alias Stevedore.{Build, Digest, Image, Manifest, MediaType, Sign, Transport, Verify}
  alias Stevedore.Sign.Sigstore

  @moduletag :interop

  @registry_url "http://localhost:5000"
  @registry_host "localhost:5000"

  # A fixed, non-empty key password. cosign reads it from COSIGN_PASSWORD; an *empty* value can't be
  # passed through `System.cmd`'s env (Erlang drops it, so cosign would prompt and hang), so we use a
  # constant the keygen/sign calls share. Verify needs no password (public key only).
  @cosign_password "stevedore-9g"

  # Whole suite is gated at compile time on cosign + a reachable registry:2, since every case needs
  # both. A machine missing either gets one cleanly-skipped placeholder instead of N failures.
  if available?("cosign") and Stevedore.TestTools.registry_up?(@registry_url) do
    describe "Stevedore signs → cosign verifies" do
      test "cosign verify --key accepts a Stevedore signature on a plain image" do
        key = Sigstore.generate_key()
        pub = write_pub(key)

        {image, t, ref} = push_image(built("dir1-plain"))

        {:ok, sig} = Sign.sigstore(image, key, reference: ref)
        push_signature(sig, t)

        assert {_out, 0} = cosign_verify(pub, ref)
      end

      test "cosign verify --key accepts a Stevedore signature carrying payload annotations" do
        # The optional simple-signing section must not break verification — cosign signs/verifies the
        # whole payload, annotations included.
        key = Sigstore.generate_key()
        pub = write_pub(key)

        {image, t, ref} = push_image(built("dir1-annot", %{labels: %{"team" => "stevedore"}}))

        {:ok, sig} =
          Sign.sigstore(image, key,
            reference: ref,
            annotations: %{"env" => "test", "step" => "9g"}
          )

        push_signature(sig, t)

        assert {_out, 0} = cosign_verify(pub, ref)
      end

      test "cosign verify --key accepts a Stevedore signature on a multi-arch index digest" do
        # A signature over an image index (not a single manifest). cosign resolves the digest we give
        # it and looks for `sha256-<indexdigest>.sig`; Sign.sigstore over the index Digest must land
        # the artifact at exactly that tag with a matching docker-manifest-digest payload.
        key = Sigstore.generate_key()
        pub = write_pub(key)

        {index_digest, t, ref} = push_index(["amd64", "arm64"])

        {:ok, sig} =
          Sign.sigstore(index_digest, key,
            reference: ref,
            subject_media_type: MediaType.oci_index()
          )

        push_signature(sig, t)

        assert {_out, 0} = cosign_verify(pub, ref)
      end
    end

    describe "cosign signs → Stevedore verifies" do
      test "Stevedore.Verify.image accepts a cosign signature under the matching public key" do
        keydir = cosign_keygen()
        {image, t, ref} = push_image(built("dir2-ok"))

        cosign_sign(keydir, ref)

        policy = %{keys: [File.read!(keypath(keydir, "pub"))], require: :any}

        assert {:ok, [%{} | _]} = Verify.image(image, policy, transport: t)
      end

      test "Stevedore.Verify.image rejects a cosign signature under the wrong public key (default-deny)" do
        signer = cosign_keygen()
        # A second, unrelated keypair — its public half must NOT verify `signer`'s signature.
        attacker = cosign_keygen()

        {image, t, ref} = push_image(built("dir2-wrong"))

        cosign_sign(signer, ref)

        policy = %{keys: [File.read!(keypath(attacker, "pub"))], require: :any}

        assert {:error, %Verify.Error{reason: :no_valid_signature}} =
                 Verify.image(image, policy, transport: t)
      end
    end

    describe "encoding cross-checks" do
      test "the signature annotation key equals cosign's dev.cosignproject.cosign/signature" do
        # cosign SIGNATURE_SPEC: the base64 signature lives under this exact layer annotation.
        assert Sign.signature_annotation() == "dev.cosignproject.cosign/signature"
      end

      test "the payload media type equals cosign's simple-signing media type" do
        # cosign SIGNATURE_SPEC: the payload layer carries this media type.
        assert Sign.payload_media_type() == "application/vnd.dev.cosign.simplesigning.v1+json"
      end

      test "Stevedore tags its signature artifact at the same sha256-<hex>.sig as cosign does" do
        # Asymmetric: let cosign create the signature (so the tag is cosign's own), then assert the
        # Stevedore-produced artifact for the same image carries the identical tag string. Proves
        # Sign.sig_tag/1's convention matches cosign's tag-based discovery scheme byte-for-byte.
        keydir = cosign_keygen()
        {image, t, ref} = push_image(built("xcheck-tag"))

        cosign_sign(keydir, ref)

        expected = expected_sig_tag(image)

        assert tag_present?(t, expected),
               "cosign did not create #{expected}; tags: #{inspect(tags(t))}"

        # Our artifact, signed with a Stevedore key, must declare the same tag.
        {:ok, sig} = Sign.sigstore(image, Sigstore.generate_key())
        assert sig.tag == expected
      end

      test "the simple-signing critical subtree matches cosign's for the same digest" do
        # Byte-compare where it must match: critical.type and critical.image.docker-manifest-digest
        # are spec-fixed. (docker-reference is informational and tool-dependent, so it is excluded.)
        keydir = cosign_keygen()
        {image, t, ref} = push_image(built("xcheck-payload"))

        cosign_sign(keydir, ref)

        cosign_payload = JSON.decode!(fetch_signature_payload(t, Image.digest(image)))
        ours = JSON.decode!(Sigstore.payload(Image.digest(image)))

        assert ours["critical"]["type"] == cosign_payload["critical"]["type"]
        assert ours["critical"]["type"] == "cosign container image signature"

        assert ours["critical"]["image"]["docker-manifest-digest"] ==
                 cosign_payload["critical"]["image"]["docker-manifest-digest"]

        assert ours["critical"]["image"]["docker-manifest-digest"] ==
                 Digest.to_string(Image.digest(image))
      end
    end
  else
    @tag skip: "sign interop needs cosign and a reachable registry:2 at #{@registry_url}"
    test "sign ↔ cosign (skipped: no cosign or no registry)" do
      :ok
    end
  end

  # --- image / index fixtures pushed to the registry ---

  # A single-layer image whose content is keyed on `label` so each case has a distinct digest (and
  # thus a distinct `.sig` tag — signatures never collide across cases).
  defp built(label, config \\ %{}) do
    content = "stevedore step-9g sign interop: #{label}\n"

    entries = [
      %{
        name: "etc/#{label}.txt",
        type: :regular,
        mode: 0o644,
        size: byte_size(content),
        linkname: nil,
        content: content
      }
    ]

    {:ok, image} = Build.image([entries], Map.merge(%{cmd: ["/bin/true"]}, config))
    image
  end

  # Push `image` to a fresh repo on registry:2 over HTTP. Returns {image, transport, digest_ref}
  # where digest_ref is `localhost:5000/<repo>@<digest>` — the unambiguous form cosign and our
  # verifier both key off.
  defp push_image(image) do
    t = transport(unique_repo("img"))
    assert {:ok, %{digest: digest}} = Stevedore.copy(image, {t, "v1"})
    {image, t, "#{@registry_host}/#{t.repository}@#{Digest.to_string(digest)}"}
  end

  # Build N single-platform children, push each + a referencing index to one repo, and return
  # {index_digest, transport, digest_ref}.
  defp push_index(arches) do
    t = transport(unique_repo("idx"))

    manifests =
      Enum.map(arches, fn arch ->
        {:ok, child} = Build.image([index_layer("idx-#{arch}")], %{}, platform: "linux/#{arch}")
        assert {:ok, _} = Stevedore.copy(child, {t, Digest.to_string(Image.digest(child))})

        %{
          "mediaType" => child.manifest.media_type,
          "size" => byte_size(child.manifest.raw),
          "digest" => Digest.to_string(Image.digest(child)),
          "platform" => %{"os" => "linux", "architecture" => arch}
        }
      end)

    index_raw =
      JSON.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => MediaType.oci_index(),
        "manifests" => manifests
      })

    assert {:ok, index_digest} =
             Transport.put_manifest(t, "v1", index_raw, MediaType.oci_index())

    {index_digest, t, "#{@registry_host}/#{t.repository}@#{Digest.to_string(index_digest)}"}
  end

  defp index_layer(name) do
    content = "#{name}\n"

    [
      %{
        name: name,
        type: :regular,
        mode: 0o644,
        size: byte_size(content),
        linkname: nil,
        content: content
      }
    ]
  end

  # Push a Stevedore signature artifact to its `sha256-<hex>.sig` tag in the same repo.
  defp push_signature(%Image{tag: tag} = sig, t) do
    assert {:ok, _} = Stevedore.copy(sig, {t, tag})
  end

  defp transport(repo),
    do: %Transport.Registry{registry: @registry_host, repository: repo, opts: [scheme: "http"]}

  defp unique_repo(kind), do: "stevedore-9g/#{kind}-#{System.unique_integer([:positive])}"

  # --- reading signatures back off the registry (for the payload cross-check) ---

  # The simple-signing payload bytes cosign stored: fetch the `.sig` manifest, find the layer with
  # the cosign signature annotation, return its blob.
  defp fetch_signature_payload(t, %Digest{} = subject) do
    {:ok, fetched} = Transport.get_manifest(t, sig_tag(subject))
    {:ok, manifest} = Manifest.parse(fetched.raw, fetched.media_type)
    {:ok, layers} = Manifest.layers(manifest)

    layer =
      Enum.find(layers, fn l ->
        is_map(l.annotations) and Map.has_key?(l.annotations, Sign.signature_annotation())
      end)

    {:ok, payload} = Transport.get_blob(t, layer.digest)
    payload
  end

  defp tags(t) do
    case Transport.list_tags(t) do
      {:ok, tags} -> tags
      _ -> []
    end
  end

  defp tag_present?(t, tag), do: tag in tags(t)

  defp expected_sig_tag(image), do: sig_tag(Image.digest(image))
  defp sig_tag(%Digest{algorithm: algorithm, hex: hex}), do: "#{algorithm}-#{hex}.sig"

  # --- cosign key handling ---

  # `cosign generate-key-pair` in a fresh tmp dir with an empty password, returning that dir. Yields
  # cosign.key (encrypted private) + cosign.pub (plain PEM public).
  defp cosign_keygen do
    dir = fresh_dir("cosign-keys")
    cosign!(["generate-key-pair"], cd: dir)
    dir
  end

  defp keypath(dir, "key"), do: Path.join(dir, "cosign.key")
  defp keypath(dir, "pub"), do: Path.join(dir, "cosign.pub")

  # Export a Stevedore keypair's public half to a PEM file cosign verify --key can read.
  defp write_pub(%{public: pem}) do
    path = Path.join(fresh_dir("stevedore-pub"), "pub.pem")
    File.write!(path, pem)
    path
  end

  # --- cosign invocation ---

  # Sign `ref` keyed and offline, in the **legacy simple-signing** format Stevedore implements.
  # cosign 3.x flipped three defaults that must each be reverted for interop:
  #
  #   * `--new-bundle-format=false` — 3.x defaults to a Sigstore DSSE bundle
  #     (`application/vnd.dev.sigstore.bundle.v0.3+json`); we want the `simplesigning` layer carrying
  #     the `dev.cosignproject.cosign/signature` annotation (cosign SIGNATURE_SPEC).
  #   * `--use-signing-config=false` — 3.x defaults to a TUF signing config mandating a Rekor tlog;
  #     the legacy keyed flow needs this off before `--tlog-upload=false` is accepted.
  #   * `--registry-referrers-mode=legacy` — store the signature at the `sha256-<digest>.sig` tag
  #     both cosign's tag-based verify and `Stevedore.Verify` look for (not the OCI 1.1 referrers
  #     API, which the compose `registry:2` doesn't serve anyway).
  defp cosign_sign(keydir, ref) do
    cosign!(
      [
        "sign",
        "--key",
        keypath(keydir, "key"),
        "--new-bundle-format=false",
        "--use-signing-config=false",
        "--tlog-upload=false",
        "-y",
        "--registry-referrers-mode=legacy" | http()
      ] ++ [ref]
    )
  end

  defp cosign_verify(pub, ref) do
    cosign(["verify", "--key", pub, "--insecure-ignore-tlog" | http()] ++ [ref])
  end

  # Plain-HTTP flag for the compose registry. Shared by sign and verify; `--registry-referrers-mode`
  # is sign-only (verify rejects it), so it is added at the sign call site, not here.
  defp http, do: ["--allow-http-registry"]

  # Run cosign with the shared key password in the environment, returning {output, exit_code}.
  defp cosign(args, opts \\ []) do
    System.cmd(
      find("cosign"),
      args,
      [stderr_to_stdout: true, env: [{"COSIGN_PASSWORD", @cosign_password}]] ++ opts
    )
  end

  defp cosign!(args, opts \\ []) do
    {out, code} = cosign(args, opts)
    assert code == 0, "`cosign #{Enum.join(args, " ")}` exited #{code}:\n#{out}"
    out
  end

  defp fresh_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "stevedore-9g-#{name}-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
