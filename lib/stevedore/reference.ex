defmodule Stevedore.Reference do
  @moduledoc """
  A parsed, normalized image reference: registry, repository, and a tag or digest.

  Parsing applies Docker/OCI normalization (the `distribution/reference` rules): a name with no
  registry component defaults to Docker Hub (`registry-1.docker.io`), a single-segment Hub repo
  gets the `library/` prefix, and a reference with neither tag nor digest defaults to the
  `latest` tag.

  This models only the *name* part. Transport prefixes (`docker://`, `oci:`) are parsed by the
  transport layer in a later phase.

  Spec: [distribution/reference grammar](https://github.com/distribution/reference/blob/main/reference.go)
  and [Docker Registry HTTP API v2](https://distribution.github.io/distribution/spec/api/).
  """

  alias Stevedore.Digest

  @enforce_keys [:registry, :repository]
  defstruct [:registry, :repository, :tag, :digest]

  @type t :: %__MODULE__{
          registry: String.t(),
          repository: String.t(),
          tag: String.t() | nil,
          digest: Digest.t() | nil
        }

  @default_registry "registry-1.docker.io"
  @default_tag "latest"

  @doc """
  Parses an image reference string, applying Docker/OCI normalization.

  ## Examples

      iex> {:ok, ref} = Stevedore.Reference.parse("alpine:3.20")
      iex> {ref.registry, ref.repository, ref.tag}
      {"registry-1.docker.io", "library/alpine", "3.20"}

      iex> {:ok, ref} = Stevedore.Reference.parse("ghcr.io/owner/app")
      iex> {ref.registry, ref.repository, ref.tag}
      {"ghcr.io", "owner/app", "latest"}

      iex> {:ok, ref} = Stevedore.Reference.parse("localhost:5000/app@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
      iex> {ref.registry, ref.tag, ref.digest.algorithm}
      {"localhost:5000", nil, :sha256}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, {:bad_input, term()}}
  def parse(string) when is_binary(string) do
    # Every failing step returns `{:error, {:bad_input, _}}`, which `with` propagates as-is.
    with {:ok, {name, digest}} <- split_digest(string),
         {domain, remainder} <- split_domain(name),
         {repository, tag} <- split_tag(remainder),
         {registry, repository} <- normalize(domain, repository),
         :ok <- validate(registry, repository) do
      tag = default_tag(tag, digest)
      {:ok, %__MODULE__{registry: registry, repository: repository, tag: tag, digest: digest}}
    end
  end

  @doc """
  Renders a reference back to its canonical `registry/repository[:tag][@digest]` string.

  The output re-parses to an equal reference.

  ## Examples

      iex> {:ok, ref} = Stevedore.Reference.parse("alpine")
      iex> Stevedore.Reference.to_string(ref)
      "registry-1.docker.io/library/alpine:latest"
  """
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{} = ref) do
    base = "#{ref.registry}/#{ref.repository}"
    base = if ref.tag, do: "#{base}:#{ref.tag}", else: base
    if ref.digest, do: "#{base}@#{Digest.to_string(ref.digest)}", else: base
  end

  # A trailing `@algo:hex` names the digest; everything before it is the name.
  @spec split_digest(String.t()) ::
          {:ok, {String.t(), Digest.t() | nil}} | {:error, {:bad_input, term()}}
  defp split_digest(string) do
    case String.split(string, "@", parts: 2) do
      [name] ->
        {:ok, {name, nil}}

      [name, digest_str] ->
        case Digest.parse(digest_str) do
          {:ok, digest} -> {:ok, {name, digest}}
          {:error, _} = error -> error
        end
    end
  end

  # The first path segment is the registry only if it looks like a host (has a `.` or `:`, or is
  # "localhost"); otherwise the reference is a bare Docker Hub repository.
  @spec split_domain(String.t()) :: {String.t() | nil, String.t()}
  defp split_domain(name) do
    case String.split(name, "/", parts: 2) do
      [maybe_domain, rest] ->
        if domain?(maybe_domain), do: {maybe_domain, rest}, else: {nil, name}

      [_] ->
        {nil, name}
    end
  end

  @spec domain?(String.t()) :: boolean()
  defp domain?(segment) do
    segment == "localhost" or String.contains?(segment, ".") or String.contains?(segment, ":")
  end

  # In the de-domained remainder, a `:` separates the tag (repository paths never contain one).
  @spec split_tag(String.t()) :: {String.t(), String.t() | nil}
  defp split_tag(remainder) do
    case String.split(remainder, ":", parts: 2) do
      [repository, tag] -> {repository, tag}
      [repository] -> {repository, nil}
    end
  end

  @spec normalize(String.t() | nil, String.t()) :: {String.t(), String.t()}
  defp normalize(domain, repository) when domain in [nil, "docker.io", @default_registry] do
    repository =
      if String.contains?(repository, "/"), do: repository, else: "library/#{repository}"

    {@default_registry, repository}
  end

  defp normalize(domain, repository), do: {domain, repository}

  @spec validate(String.t(), String.t()) :: :ok | {:error, {:bad_input, term()}}
  defp validate(registry, repository) do
    if registry != "" and repository != "" do
      :ok
    else
      {:error, {:bad_input, "reference must have a registry and repository"}}
    end
  end

  @spec default_tag(String.t() | nil, Digest.t() | nil) :: String.t() | nil
  defp default_tag(nil, nil), do: @default_tag
  defp default_tag(tag, _digest), do: tag

  defimpl Inspect do
    # Like `to_string/1`, but with the (long) digest abbreviated for readability.
    def inspect(%Stevedore.Reference{} = ref, _opts) do
      base = "#{ref.registry}/#{ref.repository}"
      base = if ref.tag, do: "#{base}:#{ref.tag}", else: base
      base = if ref.digest, do: "#{base}@#{Stevedore.Digest.short(ref.digest)}", else: base
      "#Stevedore.Reference<#{base}>"
    end
  end
end
