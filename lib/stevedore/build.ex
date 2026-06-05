defmodule Stevedore.Build do
  @moduledoc """
  Assemble images **declaratively** from layers + a config — the crane-style create surface.

  Stevedore builds images as data; it never *runs* build steps (no Dockerfile `RUN`). For each
  layer it computes both digests the spec requires and keeps them straight:

    * the **diff_id** — `sha256` of the *uncompressed* tar (goes in the config's `rootfs.diff_ids`)
    * the **descriptor digest** — `sha256` of the *compressed* bytes (goes in the manifest)

  The default compression is gzip; output is OCI media types (or Docker `v2s2` via
  `format: :docker`). Builds are deterministic: layer compression and tar headers carry no
  timestamps, so the same inputs yield the same digests.

  Spec: [OCI image-spec, config](https://github.com/opencontainers/image-spec/blob/main/config.md)
  and [layer](https://github.com/opencontainers/image-spec/blob/main/layer.md); crane semantics.
  """

  alias Stevedore.{Archive, Config, Descriptor, Digest, Image, MediaType}

  @typedoc """
  A layer source: an uncompressed tar binary, a list of `t:Stevedore.Archive.entry/0`, or a
  `{path, opts}` pointing at an uncompressed tar file.
  """
  @type layer_input :: binary() | [Archive.entry()] | {Path.t(), keyword()}

  @doc """
  Builds an image from a list of layer inputs and a config.

  `config` is the runtime config — a map of `:entrypoint`/`:cmd`/`:env`/`:user`/`:working_dir`/
  `:labels`, or a `t:Stevedore.Config.t/0`. Options: `:platform` (`"os/arch"` or a keyword),
  `:format` (`:oci`/`:docker`), `:compression` (`:gzip`/`:none`/`:zstd`).

  ## Examples

      iex> tar = Stevedore.Archive.write!([%{name: "f", type: :regular, mode: 0o644, size: 2, linkname: nil, content: "hi"}])
      iex> {:ok, image} = Stevedore.Build.image([tar], %{entrypoint: ["/f"]})
      iex> length(image.layers)
      1
  """
  @spec image([layer_input()], map() | Config.t(), keyword()) ::
          {:ok, Image.t()} | {:error, term()}
  def image(layer_inputs, config, opts \\ []) when is_list(layer_inputs) do
    with {:ok, layers} <- build_layers(layer_inputs, opts) do
      Image.assemble(base_config(config, opts), layers, assemble_opts(opts))
    end
  end

  @doc """
  Builds a single-layer image from a directory tree.

  The tree is tarred with deterministic ordering and zeroed timestamps, so the same tree always
  produces the same digest.
  """
  @spec from_dir(Path.t(), map() | Config.t(), keyword()) :: {:ok, Image.t()} | {:error, term()}
  def from_dir(path, config, opts \\ []) do
    image([dir_tar(path)], config, opts)
  end

  @doc """
  Appends a layer to an image, adding a matching history entry and recomputing the manifest.
  """
  @spec append(Image.t(), layer_input(), keyword()) :: {:ok, Image.t()} | {:error, term()}
  def append(%Image{} = image, layer_input, opts \\ []) do
    with {:ok, [layer]} <-
           build_layers([layer_input], Keyword.put_new(opts, :format, Image.format(image))) do
      config_json =
        Map.update(
          image.config.json,
          "history",
          [history_entry(opts)],
          &(&1 ++ [history_entry(opts)])
        )

      Image.assemble(config_json, Image.layers(image) ++ [layer], reassemble_opts(image))
    end
  end

  # --- layers ---

  @spec build_layers([layer_input()], keyword()) :: {:ok, [Image.layer()]} | {:error, term()}
  defp build_layers(inputs, opts) do
    format = Keyword.get(opts, :format, :oci)
    compression = Keyword.get(opts, :compression, :gzip)

    Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, acc} ->
      case normalize(input) do
        {:ok, tar} -> {:cont, {:ok, [build_layer(tar, compression, format) | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  @spec build_layer(binary(), atom(), atom()) :: Image.layer()
  defp build_layer(tar, compression, format) do
    diff_id = Digest.compute(tar)
    {blob, media} = compress(tar, compression, format)

    descriptor = %Descriptor{
      media_type: media,
      digest: Digest.compute(blob),
      size: byte_size(blob)
    }

    %{descriptor: descriptor, diff_id: diff_id, blob: blob}
  end

  @spec compress(binary(), atom(), atom()) :: {binary(), String.t()}
  defp compress(tar, :none, _format), do: {tar, MediaType.oci_layer()}
  defp compress(tar, :gzip, :docker), do: {Archive.gzip(tar), MediaType.docker_layer_gzip()}
  defp compress(tar, :gzip, _format), do: {Archive.gzip(tar), MediaType.oci_layer_gzip()}
  defp compress(tar, :zstd, _format), do: {Archive.zstd(tar), MediaType.oci_layer_zstd()}

  @spec normalize(layer_input()) :: {:ok, binary()} | {:error, term()}
  defp normalize(bin) when is_binary(bin), do: {:ok, bin}
  defp normalize(entries) when is_list(entries), do: {:ok, Archive.write!(entries)}
  defp normalize({path, _opts}) when is_binary(path), do: File.read(path)

  # --- config ---

  @spec base_config(map() | Config.t(), keyword()) :: map()
  defp base_config(config, opts) do
    {os, arch} = platform(opts, config)

    %{
      "architecture" => arch,
      "os" => os,
      "config" => runtime_config(config),
      "rootfs" => %{"type" => "layers", "diff_ids" => []},
      "history" => []
    }
  end

  @spec runtime_config(map() | Config.t()) :: map()
  defp runtime_config(%Config{} = config) do
    %{}
    |> put_if("Entrypoint", config.entrypoint)
    |> put_if("Cmd", config.cmd)
    |> put_if("Env", config.env)
    |> put_if("User", config.user)
    |> put_if("WorkingDir", config.working_dir)
    |> put_if("Labels", config.labels)
  end

  defp runtime_config(map) when is_map(map) do
    %{}
    |> put_if("Entrypoint", map[:entrypoint])
    |> put_if("Cmd", map[:cmd])
    |> put_if("Env", map[:env])
    |> put_if("User", map[:user])
    |> put_if("WorkingDir", map[:working_dir])
    |> put_if("Labels", map[:labels])
  end

  @spec platform(keyword(), map() | Config.t()) :: {String.t(), String.t()}
  defp platform(opts, config) do
    case opts[:platform] do
      nil -> {config_os(config), config_arch(config)}
      str when is_binary(str) -> parse_platform(str)
      kw when is_list(kw) -> {kw[:os] || "linux", kw[:architecture] || "amd64"}
    end
  end

  defp parse_platform(string) do
    case String.split(string, "/") do
      [os, arch | _] -> {os, arch}
      [os] -> {os, "amd64"}
    end
  end

  defp config_os(%Config{os: os}) when is_binary(os), do: os
  defp config_os(_), do: "linux"
  defp config_arch(%Config{architecture: arch}) when is_binary(arch), do: arch
  defp config_arch(_), do: "amd64"

  # --- helpers ---

  @spec assemble_opts(keyword()) :: keyword()
  defp assemble_opts(opts), do: [format: Keyword.get(opts, :format, :oci)]

  @spec reassemble_opts(Image.t()) :: keyword()
  defp reassemble_opts(image),
    do: [format: Image.format(image), annotations: Image.annotations(image)]

  defp history_entry(opts), do: %{"created_by" => opts[:created_by] || "stevedore build"}

  @spec put_if(map(), String.t(), term()) :: map()
  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  # Deterministic tar of a directory tree: sorted entries, zeroed mtime/uid/gid.
  @spec dir_tar(Path.t()) :: binary()
  defp dir_tar(root) do
    root |> walk(root) |> Archive.write!()
  end

  @spec walk(Path.t(), Path.t()) :: [Archive.entry()]
  defp walk(root, dir) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      full = Path.join(dir, name)
      rel = Path.relative_to(full, root)
      entry(full, rel) ++ if File.dir?(full), do: walk(root, full), else: []
    end)
  end

  @spec entry(Path.t(), String.t()) :: [Archive.entry()]
  defp entry(full, rel) do
    case File.read_link(full) do
      {:ok, target} ->
        [%{name: rel, type: :symlink, mode: 0o777, size: 0, linkname: target, content: nil}]

      _ ->
        if File.dir?(full) do
          [
            %{
              name: rel <> "/",
              type: :directory,
              mode: 0o755,
              size: 0,
              linkname: nil,
              content: nil
            }
          ]
        else
          content = File.read!(full)

          [
            %{
              name: rel,
              type: :regular,
              mode: 0o644,
              size: byte_size(content),
              linkname: nil,
              content: content
            }
          ]
        end
    end
  end
end
