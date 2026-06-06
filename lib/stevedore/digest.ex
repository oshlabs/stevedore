defmodule Stevedore.Digest do
  @moduledoc """
  A content digest: an `algorithm:hex` pair identifying bytes by their hash.

  Digests are the unit of content addressing throughout OCI — manifests, configs, and layers
  are all referenced by digest, and the digest is always computed over the **raw bytes** as they
  appear on the wire (never over a re-serialized form).

  Spec: [OCI image-spec, descriptor "Digests"](https://github.com/opencontainers/image-spec/blob/main/descriptor.md#digests).
  """

  @enforce_keys [:algorithm, :hex]
  defstruct [:algorithm, :hex]

  @type algorithm :: :sha256 | :sha512

  @type t :: %__MODULE__{algorithm: algorithm(), hex: String.t()}

  # Lowercase-hex length per algorithm (sha256 -> 256 bits -> 64 hex chars).
  @hex_length %{sha256: 64, sha512: 128}

  @doc """
  Computes the digest of `data` with `algorithm` (default `:sha256`).

  ## Examples

      iex> Stevedore.Digest.compute("") |> to_string()
      "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

      iex> Stevedore.Digest.compute("hello", :sha256).hex
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
  """
  @spec compute(iodata(), algorithm()) :: t()
  def compute(data, algorithm \\ :sha256) when algorithm in [:sha256, :sha512] do
    hex = :crypto.hash(algorithm, data) |> Base.encode16(case: :lower)
    %__MODULE__{algorithm: algorithm, hex: hex}
  end

  @doc """
  Parses an `"algorithm:hex"` string into a digest.

  Rejects unknown algorithms, wrong hex length, and non-lowercase-hex — never converts the
  algorithm with `String.to_atom/1` (it is matched against a fixed allowlist).

  ## Examples

      iex> {:ok, d} = Stevedore.Digest.parse("sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
      iex> {d.algorithm, byte_size(d.hex)}
      {:sha256, 64}

      iex> Stevedore.Digest.parse("sha256:nothex")
      {:error, {:bad_input, "invalid digest \\"sha256:nothex\\""}}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:bad_input, term()}}
  def parse(string) when is_binary(string) do
    with [algo, hex] <- String.split(string, ":", parts: 2),
         {:ok, algorithm} <- known_algorithm(algo),
         true <- valid_hex?(hex, algorithm) do
      {:ok, %__MODULE__{algorithm: algorithm, hex: hex}}
    else
      _ -> {:error, {:bad_input, "invalid digest #{inspect(string)}"}}
    end
  end

  @doc """
  Renders a digest as its canonical `"algorithm:hex"` string.

  Also available via `Kernel.to_string/1` through `String.Chars`.

  ## Examples

      iex> Stevedore.Digest.to_string(%Stevedore.Digest{algorithm: :sha256, hex: "abc"})
      "sha256:abc"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{algorithm: algorithm, hex: hex}) do
    "#{algorithm}:#{hex}"
  end

  @doc """
  Renders a short, display-only form — the algorithm with the hex truncated to 12 characters.

  For logs and `Inspect`, not as an identifier: it is **not** collision-free. Use `to_string/1`
  when you need the full, stable digest.

  ## Examples

      iex> Stevedore.Digest.short(Stevedore.Digest.compute(""))
      "sha256:e3b0c44298fc…"
  """
  @spec short(t()) :: String.t()
  def short(%__MODULE__{algorithm: algorithm, hex: hex}) do
    case hex do
      <<head::binary-size(12), _::binary>> -> "#{algorithm}:#{head}…"
      _ -> "#{algorithm}:#{hex}"
    end
  end

  @doc """
  Verifies that `data` hashes to `digest`.

  ## Examples

      iex> Stevedore.Digest.verify("hello", Stevedore.Digest.compute("hello"))
      :ok

      iex> Stevedore.Digest.verify("tampered", Stevedore.Digest.compute("hello"))
      {:error, :digest_mismatch}
  """
  @spec verify(iodata(), t()) :: :ok | {:error, :digest_mismatch}
  def verify(data, %__MODULE__{algorithm: algorithm} = digest) do
    if compute(data, algorithm) == digest, do: :ok, else: {:error, :digest_mismatch}
  end

  @doc """
  Returns the `"algorithm/hex"` path segment used by the OCI blob layout (`blobs/<algo>/<hex>`).

  ## Examples

      iex> Stevedore.Digest.compute("") |> Stevedore.Digest.to_path()
      "sha256/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  """
  @spec to_path(t()) :: String.t()
  def to_path(%__MODULE__{algorithm: algorithm, hex: hex}), do: "#{algorithm}/#{hex}"

  @spec known_algorithm(String.t()) :: {:ok, algorithm()} | :error
  defp known_algorithm("sha256"), do: {:ok, :sha256}
  defp known_algorithm("sha512"), do: {:ok, :sha512}
  defp known_algorithm(_), do: :error

  @spec valid_hex?(String.t(), algorithm()) :: boolean()
  defp valid_hex?(hex, algorithm) do
    byte_size(hex) == @hex_length[algorithm] and
      String.match?(hex, ~r/\A[0-9a-f]+\z/)
  end

  defimpl String.Chars do
    def to_string(digest), do: Stevedore.Digest.to_string(digest)
  end

  defimpl Inspect do
    def inspect(digest, _opts), do: "#Stevedore.Digest<#{Stevedore.Digest.short(digest)}>"
  end
end
