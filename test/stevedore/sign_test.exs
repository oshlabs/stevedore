defmodule Stevedore.SignTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Archive, Build, Image, Sign, Verify}
  alias Stevedore.Sign.Sigstore

  defp reg(name, content),
    do: %{
      name: name,
      type: :regular,
      mode: 0o644,
      size: byte_size(content),
      linkname: nil,
      content: content
    }

  defp build_image, do: Build.image([Archive.write!([reg("f", "x")])], %{}) |> elem(1)

  describe "Sigstore crypto" do
    test "generates a keypair and round-trips sign/verify" do
      key = Sigstore.generate_key()
      assert key.private =~ "BEGIN EC PRIVATE KEY"
      assert key.public =~ "BEGIN PUBLIC KEY"

      sig = Sigstore.sign("payload", key)
      assert Sigstore.verify("payload", sig, key)
      assert Sigstore.verify("payload", sig, key.public)
      refute Sigstore.verify("tampered", sig, key)
    end

    test "a different key does not verify" do
      key = Sigstore.generate_key()
      other = Sigstore.generate_key()
      sig = Sigstore.sign("payload", key)
      refute Sigstore.verify("payload", sig, other.public)
    end
  end

  describe "sigstore/3 + verify" do
    setup do
      %{image: build_image(), key: Sigstore.generate_key()}
    end

    test "produces a cosign signature artifact bound to the subject", %{image: image, key: key} do
      assert {:ok, artifact} = Sign.sigstore(image, key)
      assert artifact.tag == "sha256-#{Image.digest(image).hex}.sig"
      assert artifact.manifest.json["subject"]["digest"] == to_string(Image.digest(image))
      assert [%{annotations: %{}} = layer] = artifact.layers
      assert layer.media_type == Sign.payload_media_type()
      assert Map.has_key?(layer.annotations, Sign.signature_annotation())
    end

    test "verify accepts a valid signature against the policy key", %{image: image, key: key} do
      {:ok, artifact} = Sign.sigstore(image, key)
      assert {:ok, [_ | _]} = Verify.image(image, %{keys: [key.public]}, signatures: [artifact])
    end

    test "verify default-denies an unknown key (no valid signature)", %{image: image, key: key} do
      {:ok, artifact} = Sign.sigstore(image, key)
      other = Sigstore.generate_key()

      assert {:error, %Verify.Error{reason: :no_valid_signature}} =
               Verify.image(image, %{keys: [other.public]}, signatures: [artifact])
    end

    test "require: :all needs every key to have a signature", %{image: image, key: key} do
      other = Sigstore.generate_key()
      {:ok, a1} = Sign.sigstore(image, key)
      {:ok, a2} = Sign.sigstore(image, other)

      policy = %{keys: [key.public, other.public], require: :all}
      assert {:ok, verified} = Verify.image(image, policy, signatures: [a1, a2])
      assert length(verified) == 2

      assert {:error, _} = Verify.image(image, policy, signatures: [a1])
    end
  end

  describe "simple/3" do
    test "produces a native detached signature verifiable with the public key" do
      image = build_image()
      key = Sigstore.generate_key()

      assert {:ok, der} = Sign.simple(image, key)
      pub = Sigstore.public_key(key.public)
      assert :public_key.verify(to_string(Image.digest(image)), :sha256, der, pub)
    end
  end
end
