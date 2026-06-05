defmodule Stevedore.Sign do
  @moduledoc """
  Sign an image so its authenticity can later be verified by `Stevedore.Verify`.

  `sigstore/3` produces a **cosign-compatible** signature artifact: a small OCI image whose single
  layer is the [simple-signing payload](`Stevedore.Sign.Sigstore`) and whose layer annotation
  carries the base64 signature (`dev.cosignproject.cosign/signature`). The artifact's `subject`
  points at the signed image (OCI 1.1 referrer) and its `tag` is cosign's `sha256-<hex>.sig`. Push
  it with `Stevedore.copy/3` or attach it with `Stevedore.Referrers.attach/4`.

  `simple/3` is a Stevedore-native detached signature over the manifest digest (ECDSA). It is
  *not* the containers/image GPG "simple signing" wire format — GPG interop is a future opt-in.

  All crypto is native (`:public_key`); nothing shells out to `cosign`/`gpg`/`openssl`.

  Spec: [cosign SIGNATURE_SPEC](https://github.com/sigstore/cosign/blob/main/specs/SIGNATURE_SPEC.md).
  """

  alias Stevedore.{Config, Descriptor, Digest, Image, Manifest, MediaType}
  alias Stevedore.Sign.{Error, Sigstore}

  @cosign_payload_media "application/vnd.dev.cosign.simplesigning.v1+json"
  @cosign_signature_annotation "dev.cosignproject.cosign/signature"

  @doc """
  Signs `subject` (an image or a manifest digest) with `key`, returning the cosign signature
  artifact as an `Stevedore.Image.t/0` ready to copy or attach.

  `opts`: `:reference` (docker-reference in the payload), `:annotations` (payload optional
  section). For a bare digest, `:subject_size`/`:subject_media_type` describe the subject.
  """
  @spec sigstore(Image.t() | Digest.t(), Sigstore.key(), keyword()) ::
          {:ok, Image.t()} | {:error, Error.t()}
  def sigstore(subject, key, opts \\ []) do
    descriptor = subject_descriptor(subject, opts)
    payload = Sigstore.payload(descriptor.digest, opts)
    signature = Sigstore.sign(payload, key)
    {:ok, artifact(descriptor, payload, signature, opts)}
  rescue
    error -> {:error, %Error{reason: Exception.message(error)}}
  end

  @doc """
  Produces a native detached ECDSA signature (DER bytes) over `subject`'s manifest digest.
  """
  @spec simple(Image.t() | Digest.t(), Sigstore.key(), keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def simple(subject, key, opts \\ []) do
    descriptor = subject_descriptor(subject, opts)

    {:ok,
     :public_key.sign(Digest.to_string(descriptor.digest), :sha256, Sigstore.private_key(key))}
  rescue
    error -> {:error, %Error{reason: Exception.message(error)}}
  end

  @doc "The layer-annotation key cosign stores its signature under."
  @spec signature_annotation() :: String.t()
  def signature_annotation, do: @cosign_signature_annotation

  @doc "The media type of the cosign simple-signing payload layer."
  @spec payload_media_type() :: String.t()
  def payload_media_type, do: @cosign_payload_media

  @spec subject_descriptor(Image.t() | Digest.t(), keyword()) :: Descriptor.t()
  defp subject_descriptor(%Image{} = image, _opts) do
    %Descriptor{
      media_type: image.manifest.media_type,
      digest: Image.digest(image),
      size: byte_size(image.manifest.raw)
    }
  end

  defp subject_descriptor(%Digest{} = digest, opts) do
    %Descriptor{
      media_type: opts[:subject_media_type] || MediaType.oci_manifest(),
      digest: digest,
      size: opts[:subject_size] || 0
    }
  end

  # Build the cosign signature artifact image: empty config, the payload as the single layer with
  # the signature annotation, a subject pointing at the signed image, and the `.sig` tag.
  @spec artifact(Descriptor.t(), binary(), binary(), keyword()) :: Image.t()
  defp artifact(subject, payload, signature, _opts) do
    config_blob = "{}"

    config = %Descriptor{
      media_type: MediaType.oci_config(),
      digest: Digest.compute(config_blob),
      size: byte_size(config_blob)
    }

    layer = %Descriptor{
      media_type: @cosign_payload_media,
      digest: Digest.compute(payload),
      size: byte_size(payload),
      annotations: %{@cosign_signature_annotation => signature}
    }

    manifest_json = %{
      "schemaVersion" => 2,
      "mediaType" => MediaType.oci_manifest(),
      "artifactType" => @cosign_payload_media,
      "config" => Descriptor.to_json(config),
      "layers" => [Descriptor.to_json(layer)],
      "subject" => Descriptor.to_json(subject)
    }

    manifest_raw = JSON.encode!(manifest_json)
    {:ok, manifest} = Manifest.parse(manifest_raw, MediaType.oci_manifest())
    {:ok, config_struct} = Config.parse(config_blob)

    %Image{
      manifest: manifest,
      config: config_struct,
      layers: [layer],
      blobs: %{to_string(config.digest) => config_blob, to_string(layer.digest) => payload},
      tag: sig_tag(subject.digest)
    }
  end

  @spec sig_tag(Digest.t()) :: String.t()
  defp sig_tag(%Digest{algorithm: algorithm, hex: hex}), do: "#{algorithm}-#{hex}.sig"
end
