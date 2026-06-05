defmodule Stevedore.Verify do
  @moduledoc """
  Verify an image's signatures against a policy. Default-deny: verification fails unless a
  signature satisfies the policy.

  Signatures are supplied directly (`opts[:signatures]`, a list of cosign signature artifact
  images) or fetched from a transport (`opts[:transport]`) via the Referrers API / the cosign
  `.sig` tag. Each cosign signature layer's payload is checked against the policy's public keys
  with native ECDSA (`Stevedore.Sign.Sigstore`).

  Spec: [cosign SIGNATURE_SPEC](https://github.com/sigstore/cosign/blob/main/specs/SIGNATURE_SPEC.md).
  """

  alias Stevedore.{Config, Digest, Image, Manifest, Referrers, Sign, Transport}
  alias Stevedore.Sign.Sigstore
  alias Stevedore.Verify.Error

  @type pubkey :: binary() | tuple()
  @type policy :: %{optional(:keys) => [pubkey()], optional(:require) => :any | :all}
  @type verified :: %{key: pubkey(), signature: String.t()}

  @doc """
  Verifies `subject` against `policy`, returning the signatures that passed.

  `policy` is `%{keys: [public_key], require: :any | :all}` (`:any` by default). `opts` must
  carry `:signatures` (signature artifact images) or `:transport` (to fetch them).
  """
  @spec image(Image.t() | Digest.t(), policy(), keyword()) ::
          {:ok, [verified()]} | {:error, Error.t()}
  def image(subject, policy, opts \\ []) do
    with {:ok, artifacts} <- signatures(subject, opts) do
      verified = Enum.flat_map(artifacts, &verify_artifact(&1, policy))

      if satisfied?(verified, policy) do
        {:ok, verified}
      else
        {:error, %Error{reason: :no_valid_signature}}
      end
    end
  end

  # --- gather signatures ---

  @spec signatures(Image.t() | Digest.t(), keyword()) :: {:ok, [Image.t()]} | {:error, Error.t()}
  defp signatures(subject, opts) do
    cond do
      opts[:signatures] -> {:ok, opts[:signatures]}
      opts[:transport] -> fetch_signatures(subject, opts[:transport], opts)
      true -> {:error, %Error{reason: "no signatures: pass :signatures or :transport"}}
    end
  end

  @spec fetch_signatures(Image.t() | Digest.t(), Transport.t(), keyword()) ::
          {:ok, [Image.t()]} | {:error, Error.t()}
  defp fetch_signatures(subject, transport, _opts) do
    digest = subject_digest(subject)

    referrer_digests =
      case Referrers.list(transport, digest) do
        {:ok, manifest} -> referrer_digests(manifest)
        {:error, _} -> []
      end

    refs = Enum.uniq([sig_tag(digest) | referrer_digests])

    artifacts =
      refs
      |> Enum.map(&fetch_artifact(transport, &1))
      |> Enum.flat_map(fn
        {:ok, image} -> [image]
        _ -> []
      end)

    {:ok, artifacts}
  end

  @spec fetch_artifact(Transport.t(), Transport.ref()) :: {:ok, Image.t()} | {:error, term()}
  defp fetch_artifact(transport, ref) do
    with {:ok, fetched} <- Transport.get_manifest(transport, ref),
         {:ok, manifest} <- Manifest.parse(fetched.raw, fetched.media_type),
         {:ok, config} <- Manifest.config(manifest),
         {:ok, layers} <- Manifest.layers(manifest),
         {:ok, blobs} <- fetch_blobs(transport, [config | layers]) do
      {:ok,
       %Image{
         manifest: manifest,
         config: %Config{raw: "{}", json: %{}},
         layers: layers,
         blobs: blobs
       }}
    end
  end

  defp fetch_blobs(transport, descriptors) do
    Enum.reduce_while(descriptors, {:ok, %{}}, fn descriptor, {:ok, acc} ->
      case Transport.get_blob(transport, descriptor.digest) do
        {:ok, bytes} -> {:cont, {:ok, Map.put(acc, to_string(descriptor.digest), bytes)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # --- verification ---

  @spec verify_artifact(Image.t(), policy()) :: [verified()]
  defp verify_artifact(%Image{layers: layers} = image, policy) do
    keys = policy[:keys] || []

    for layer <- layers,
        signature = signature_of(layer),
        signature != nil,
        {:ok, payload} <- [Image.blob(image, layer.digest)],
        key <- keys,
        Sigstore.verify(payload, signature, key) do
      %{key: key, signature: to_string(layer.digest)}
    end
  end

  defp signature_of(%{annotations: annotations}) when is_map(annotations),
    do: annotations[Sign.signature_annotation()]

  defp signature_of(_), do: nil

  @spec satisfied?([verified()], policy()) :: boolean()
  defp satisfied?(verified, policy) do
    case policy[:require] || :any do
      :any -> verified != []
      :all -> Enum.all?(policy[:keys] || [], fn key -> Enum.any?(verified, &(&1.key == key)) end)
    end
  end

  defp subject_digest(%Image{} = image), do: Image.digest(image)
  defp subject_digest(%Digest{} = digest), do: digest

  defp referrer_digests(%Manifest{json: json}) do
    for entry <- json["manifests"] || [],
        {:ok, digest} <- [Digest.parse(entry["digest"])],
        do: digest
  end

  defp sig_tag(%Digest{algorithm: algorithm, hex: hex}), do: "#{algorithm}-#{hex}.sig"
end
