defmodule Stevedore.Sign.Sigstore do
  @moduledoc """
  Sigstore/cosign key-pair primitives, native via `:public_key` (ECDSA P-256, no shelling out).

  Provides key generation (PEM, the format `cosign` reads and writes), detached signing and
  verification of a payload, and construction of the cosign **simple signing** payload that binds
  an image's manifest digest. Keyless signing (Fulcio/Rekor) is a future opt-in.

  Spec: [cosign SIGNATURE_SPEC](https://github.com/sigstore/cosign/blob/main/specs/SIGNATURE_SPEC.md).
  """

  alias Stevedore.Digest

  # prime256v1 / secp256r1 — the curve cosign uses by default.
  @curve_oid {1, 2, 840, 10045, 3, 1, 7}

  @type keypair :: %{private: binary(), public: binary()}
  @type key :: binary() | keypair() | tuple()

  @doc """
  Generates an ECDSA P-256 keypair as PEM strings (`%{private: ..., public: ...}`).
  """
  @spec generate_key() :: keypair()
  def generate_key do
    private = :public_key.generate_key({:namedCurve, :secp256r1})
    {:ECPrivateKey, _v, _k, _params, point, _} = private
    public = {{:ECPoint, point}, {:namedCurve, @curve_oid}}

    %{
      private: :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, private)]),
      public:
        :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public)])
    }
  end

  @doc "Signs `payload` with `key`'s private key, returning a base64 DER ECDSA signature."
  @spec sign(iodata(), key()) :: binary()
  def sign(payload, key) do
    payload |> :public_key.sign(:sha256, private_key(key)) |> Base.encode64()
  end

  @doc "Verifies a base64 DER signature over `payload` against `key`'s public key."
  @spec verify(iodata(), binary(), key()) :: boolean()
  def verify(payload, signature_b64, key) do
    with {:ok, der} <- Base.decode64(signature_b64) do
      :public_key.verify(payload, :sha256, der, public_key(key))
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Builds the cosign simple-signing payload binding `digest`. `opts[:reference]` sets the
  docker-reference; `opts[:annotations]` populates the optional section.
  """
  @spec payload(Digest.t(), keyword()) :: binary()
  def payload(%Digest{} = digest, opts \\ []) do
    JSON.encode!(%{
      "critical" => %{
        "identity" => %{"docker-reference" => opts[:reference] || ""},
        "image" => %{"docker-manifest-digest" => Digest.to_string(digest)},
        "type" => "cosign container image signature"
      },
      "optional" => opts[:annotations]
    })
  end

  @doc "Resolves a key argument to a private-key record."
  @spec private_key(key()) :: tuple()
  def private_key(%{private: pem}), do: decode(pem)
  def private_key(pem) when is_binary(pem), do: decode(pem)
  def private_key(record) when is_tuple(record), do: record

  @doc "Resolves a key argument to a public-key record."
  @spec public_key(key()) :: tuple()
  def public_key(%{public: pem}), do: decode(pem)
  def public_key(pem) when is_binary(pem), do: decode(pem)
  def public_key(record) when is_tuple(record), do: record

  @spec decode(binary()) :: tuple()
  defp decode(pem) do
    [entry | _] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end
end
