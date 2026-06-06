defmodule Stevedore.Fixtures do
  @moduledoc """
  Pinned, deterministic test fixtures shared across the integration suites.

  Two kinds of constants:

    * **Spec-defined golden values** — the OCI 1.1 empty config and the empty-bytes digest. These
      are fixed by the spec and re-asserted through `Stevedore.Digest.compute/1` in the fixtures
      test, so a drift in our own hashing is caught.
    * **Images pinned by digest** — small, stable, multi-arch images used by the `:external` and
      `:interop` steps. Pinning by digest (not tag) keeps those steps reproducible: a green run
      today stays green even if the upstream tag is re-pushed.

  Digests resolved with `crane digest <tag>` on 2026-06-06. Re-pin with the same command if an
  image is intentionally bumped, and record the date.
  """

  # OCI 1.1 "empty" descriptor: the two bytes `{}`, media type application/vnd.oci.empty.v1+json.
  # https://github.com/opencontainers/image-spec/blob/main/manifest.md#guidance-for-an-empty-descriptor
  @empty_config "{}"
  @empty_config_digest "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"

  # The empty blob (e.g. an empty layer). Also asserted in lib/stevedore/digest.ex.
  @empty_bytes ""
  @empty_bytes_digest "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  # Small, stable images pinned by digest (resolved 2026-06-06 via `crane digest`).
  @images %{
    "alpine:3.20" => "sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc",
    "busybox:1.36" => "sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662",
    "hello-world:latest" =>
      "sha256:0e760fdfbc48ba8041e7c6db999bb40bfca508b4be580ac75d32c4e29d202ce1"
  }

  @doc "The OCI empty-config bytes (`{}`)."
  @spec empty_config() :: binary()
  def empty_config, do: @empty_config

  @doc "Digest of the OCI empty config."
  @spec empty_config_digest() :: String.t()
  def empty_config_digest, do: @empty_config_digest

  @doc "The empty blob (`\"\"`)."
  @spec empty_bytes() :: binary()
  def empty_bytes, do: @empty_bytes

  @doc "Digest of the empty blob."
  @spec empty_bytes_digest() :: String.t()
  def empty_bytes_digest, do: @empty_bytes_digest

  @doc "Map of pinned `name:tag => digest` test images."
  @spec images() :: %{String.t() => String.t()}
  def images, do: @images

  @doc """
  A pinned image reference string `name@sha256:…` for `tag` (e.g. `"alpine:3.20"`).

  Raises if the tag isn't pinned, so a typo fails loudly rather than silently hitting a floating tag.
  """
  @spec image(String.t()) :: String.t()
  def image(tag) do
    digest = Map.fetch!(@images, tag)
    [repo | _] = String.split(tag, ":")
    "#{repo}@#{digest}"
  end
end
