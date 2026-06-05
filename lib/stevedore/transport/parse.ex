defmodule Stevedore.Transport.Parse do
  @moduledoc """
  Parses Skopeo-style transport-prefixed references into a `{transport, ref}` pair.

  Recognized prefixes (see `t:Stevedore.Transport.t/0` implementations):

    * `docker://name:tag` / `docker://name@digest` — a remote registry
    * `oci:path[:tag]` — an OCI image-layout directory
    * `oci-archive:path[:tag]` — an OCI image layout as a tar
    * `docker-archive:path[:tag]` — a `docker save` tarball
    * `dir:path` — a flat directory of manifest + blobs
    * `static:path[:tag]` — a Stevedore registry-v2 directory tree

  `ref` is the tag/digest portion (or `nil` for transports that hold a single image). `opts` is
  carried onto the transport (e.g. registry `:creds`).

  Spec: [containers-transports(5)](https://github.com/containers/image/blob/main/docs/containers-transports.5.md).
  """

  alias Stevedore.{Reference, Transport}

  @doc """
  Parses a transport-prefixed reference string.

  ## Examples

      iex> {:ok, {%Stevedore.Transport.OCILayout{path: "./out"}, "3.20"}} =
      ...>   Stevedore.Transport.Parse.parse("oci:./out:3.20")
      iex> :ok
      :ok
  """
  @spec parse(String.t(), keyword()) ::
          {:ok, {Transport.t(), Transport.ref()}} | {:error, {:bad_input, term()}}
  def parse(string, opts \\ [])

  def parse("docker://" <> rest, opts) do
    with {:ok, ref} <- Reference.parse(rest) do
      transport = %Transport.Registry{
        registry: ref.registry,
        repository: ref.repository,
        opts: opts
      }

      {:ok, {transport, ref.digest || ref.tag}}
    end
  end

  def parse("oci-archive:" <> rest, _opts) do
    {path, ref} = split_path_ref(rest)
    {:ok, {%Transport.Archive{path: path, format: :oci, work: work_dir()}, ref}}
  end

  def parse("oci:" <> rest, _opts) do
    {path, ref} = split_path_ref(rest)
    {:ok, {%Transport.OCILayout{path: path}, ref}}
  end

  def parse("docker-archive:" <> rest, _opts) do
    {path, ref} = split_path_ref(rest)
    {:ok, {%Transport.Archive{path: path, format: :docker, work: work_dir()}, ref}}
  end

  def parse("dir:" <> path, _opts) do
    {:ok, {%Transport.Dir{path: path}, nil}}
  end

  def parse("static:" <> rest, _opts) do
    {path, ref} = split_path_ref(rest)
    {:ok, {%Transport.Static{path: path}, ref}}
  end

  def parse(other, _opts),
    do: {:error, {:bad_input, "unknown transport reference: #{inspect(other)}"}}

  # A fresh temp work dir for tar-backed transports (`oci-archive:`/`docker-archive:`).
  @spec work_dir() :: Path.t()
  defp work_dir,
    do: Path.join(System.tmp_dir!(), "stevedore-archive-#{System.unique_integer([:positive])}")

  # "path:ref" -> {path, ref}; "path" -> {path, nil}. A leading "./" or "/" before the first
  # colon is part of the path.
  @spec split_path_ref(String.t()) :: {String.t(), String.t() | nil}
  defp split_path_ref(rest) do
    case String.split(rest, ":", parts: 2) do
      [path, ref] -> {path, ref}
      [path] -> {path, nil}
    end
  end
end
