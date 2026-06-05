defmodule Stevedore.Layer do
  @moduledoc """
  Read and merge image layers **in memory, without root**.

  A layer is a tar (usually gzip- or zstd-compressed) describing a changeset relative to the
  layer below. `merged_view/2` applies a stack of layers bottom-to-top into the effective
  filesystem, honoring OCI whiteouts:

    * `.wh.<name>` removes `<name>` (and its subtree) from the lower layers
    * `.wh..wh..opq` makes its directory *opaque* — the lower layers' contents of that directory
      are hidden

  This is the content-inspection surface a registry uses and the reading half a runtime's rootfs
  materialization builds on. It never writes to disk.

  Spec: [OCI image-spec, layer "Representing Changes"](https://github.com/opencontainers/image-spec/blob/main/layer.md#representing-changes).
  """

  alias Stevedore.{Archive, Descriptor, Image, MediaType}

  @opaque_marker ".wh..wh..opq"
  @whiteout_prefix ".wh."

  @type fs_node :: %{
          path: String.t(),
          type: :regular | :directory | :symlink | :hardlink,
          mode: non_neg_integer(),
          size: non_neg_integer(),
          linkname: String.t() | nil,
          from_layer: non_neg_integer()
        }

  @type layer_source :: binary() | Descriptor.t()

  @doc """
  Reads a single layer's tar entries, decompressing as needed.

  A `t:Stevedore.Descriptor.t/0` is decompressed by its media type and its bytes fetched from
  `opts[:image]`; a binary is decompressed by `opts[:media_type]` or sniffed by magic bytes.

  ## Examples

      iex> tar = Stevedore.Archive.write!([%{name: "f", type: :regular, mode: 0o644, size: 1, linkname: nil, content: "x"}])
      iex> {:ok, [entry]} = Stevedore.Layer.entries(Stevedore.Archive.gzip(tar))
      iex> entry.name
      "f"
  """
  @spec entries(layer_source(), keyword()) :: {:ok, [Archive.entry()]} | {:error, term()}
  def entries(layer, opts \\ [])

  def entries(bin, opts) when is_binary(bin) do
    with {:ok, tar} <- decompress(bin, opts[:media_type]), do: Archive.read(tar)
  end

  def entries(%Descriptor{} = descriptor, opts) do
    with {:ok, bytes} <- blob(descriptor, opts) do
      entries(bytes, Keyword.put(opts, :media_type, descriptor.media_type))
    end
  end

  @doc """
  Computes the whiteout-aware effective filesystem of a layer stack as a map of path to
  `t:fs_node/0` (metadata; use `Stevedore.Analyze.read_file/2` for bytes).

  Accepts a `t:Stevedore.Image.t/0` or a list of layer binaries, ordered bottom-to-top.
  """
  @spec merged_view(Image.t() | [binary()], keyword()) ::
          {:ok, %{optional(String.t()) => fs_node()}} | {:error, term()}
  def merged_view(input, opts \\ []) do
    with {:ok, merged} <- merge(input, opts) do
      {:ok,
       Map.new(merged, fn {path, %{entry: entry, from_layer: i}} ->
         {path, node(entry, path, i)}
       end)}
    end
  end

  @doc """
  Returns the effective filesystem as a flat list of tar entries (with content), sorted by path —
  the input for re-tarring a flattened image.
  """
  @spec merged_entries(Image.t() | [binary()], keyword()) ::
          {:ok, [Archive.entry()]} | {:error, term()}
  def merged_entries(input, opts \\ []) do
    with {:ok, merged} <- merge(input, opts) do
      {:ok, merged |> Map.values() |> Enum.map(& &1.entry) |> Enum.sort_by(& &1.name)}
    end
  end

  @doc """
  Diffs two layers' file contents, returning the paths `:added`, `:modified`, and `:removed`
  going from `a` to `b`. Whiteout entries are ignored (compare actual content).
  """
  @spec diff(layer_source(), layer_source(), keyword()) ::
          {:ok, %{added: [String.t()], modified: [String.t()], removed: [String.t()]}}
          | {:error, term()}
  def diff(a, b, opts \\ []) do
    with {:ok, ea} <- entries(a, opts),
         {:ok, eb} <- entries(b, opts) do
      ma = content_map(ea)
      mb = content_map(eb)
      a_keys = MapSet.new(Map.keys(ma))
      b_keys = MapSet.new(Map.keys(mb))

      {:ok,
       %{
         added: sorted(MapSet.difference(b_keys, a_keys)),
         removed: sorted(MapSet.difference(a_keys, b_keys)),
         modified:
           a_keys
           |> MapSet.intersection(b_keys)
           |> Enum.filter(&(ma[&1] != mb[&1]))
           |> Enum.sort()
       }}
    end
  end

  # --- merge core ---

  @spec merge(Image.t() | [binary()], keyword()) ::
          {:ok,
           %{optional(String.t()) => %{entry: Archive.entry(), from_layer: non_neg_integer()}}}
          | {:error, term()}
  defp merge(input, opts) do
    with {:ok, per_layer} <- read_layers(input, opts) do
      merged =
        per_layer
        |> Enum.with_index()
        |> Enum.reduce(%{}, fn {entries, index}, acc ->
          Enum.reduce(entries, acc, &apply_entry(&2, &1, index))
        end)

      {:ok, merged}
    end
  end

  @spec apply_entry(map(), Archive.entry(), non_neg_integer()) :: map()
  defp apply_entry(acc, entry, index) do
    base = Path.basename(entry.name)
    dir = normalize(Path.dirname(entry.name))

    cond do
      base == @opaque_marker ->
        drop_prefix(acc, prefix(dir))

      String.starts_with?(base, @whiteout_prefix) ->
        drop_path(acc, join(dir, base_after_prefix(base)))

      true ->
        Map.put(acc, normalize(entry.name), %{entry: entry, from_layer: index})
    end
  end

  @spec read_layers(Image.t() | [binary()], keyword()) ::
          {:ok, [[Archive.entry()]]} | {:error, term()}
  defp read_layers(%Image{} = image, _opts) do
    image
    |> Image.layers()
    |> reduce_layers(fn record -> entries(record.descriptor, image: image) end)
  end

  defp read_layers(binaries, opts) when is_list(binaries) do
    reduce_layers(binaries, fn bin -> entries(bin, opts) end)
  end

  @spec reduce_layers([term()], (term() -> {:ok, [Archive.entry()]} | {:error, term()})) ::
          {:ok, [[Archive.entry()]]} | {:error, term()}
  defp reduce_layers(items, read) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case read.(item) do
        {:ok, entries} -> {:cont, {:ok, [entries | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # --- helpers ---

  @spec node(Archive.entry(), String.t(), non_neg_integer()) :: fs_node()
  defp node(entry, path, index) do
    %{
      path: path,
      type: entry.type,
      mode: entry.mode,
      size: entry.size,
      linkname: entry.linkname,
      from_layer: index
    }
  end

  @spec content_map([Archive.entry()]) :: %{optional(String.t()) => term()}
  defp content_map(entries) do
    for entry <- entries, not whiteout?(entry.name), into: %{} do
      {normalize(entry.name), {entry.type, entry.content, entry.linkname}}
    end
  end

  defp whiteout?(name) do
    base = Path.basename(name)
    base == @opaque_marker or String.starts_with?(base, @whiteout_prefix)
  end

  @spec decompress(binary(), String.t() | nil) :: {:ok, binary()} | {:error, term()}
  defp decompress(bytes, nil), do: sniff(bytes)

  defp decompress(bytes, media_type) do
    cond do
      MediaType.gzip?(media_type) -> Archive.gunzip(bytes)
      MediaType.zstd?(media_type) -> Archive.unzstd(bytes)
      true -> {:ok, bytes}
    end
  end

  # Sniff compression by magic bytes when no media type is known.
  defp sniff(<<0x1F, 0x8B, _::binary>> = bytes), do: Archive.gunzip(bytes)
  defp sniff(<<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = bytes), do: Archive.unzstd(bytes)
  defp sniff(bytes), do: {:ok, bytes}

  @spec blob(Descriptor.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  defp blob(%Descriptor{} = descriptor, opts) do
    case opts[:image] do
      %Image{} = image -> Image.blob(image, descriptor.digest)
      _ -> {:error, {:bad_input, "reading a descriptor requires opts[:image]"}}
    end
  end

  # Drop a single path and any subtree under it (a `.wh.` whiteout).
  defp drop_path(acc, target) do
    acc
    |> Map.keys()
    |> Enum.filter(&(&1 == target or String.starts_with?(&1, target <> "/")))
    |> Enum.reduce(acc, &Map.delete(&2, &1))
  end

  # Drop everything under a directory prefix (an opaque whiteout); the directory itself stays.
  defp drop_prefix(acc, ""), do: acc

  defp drop_prefix(acc, prefix) do
    acc
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.reduce(acc, &Map.delete(&2, &1))
  end

  defp base_after_prefix(base), do: String.replace_prefix(base, @whiteout_prefix, "")

  defp prefix(""), do: ""
  defp prefix(dir), do: dir <> "/"

  defp join("", name), do: name
  defp join(dir, name), do: dir <> "/" <> name

  # Canonical path: drop a leading "./" and any trailing "/".
  @spec normalize(String.t()) :: String.t()
  defp normalize("."), do: ""

  defp normalize(name) do
    name |> String.replace_prefix("./", "") |> String.replace_suffix("/", "")
  end

  defp sorted(set), do: set |> MapSet.to_list() |> Enum.sort()
end
