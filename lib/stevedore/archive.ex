defmodule Stevedore.Archive do
  @moduledoc """
  A pure tar reader/writer plus gzip helpers.

  OCI layers are tar archives (optionally gzip- or zstd-compressed). This reads and writes them
  without shelling out to `tar`: the writer emits POSIX **ustar** headers; the reader also
  understands GNU long-name (`L`) and PAX extended-header (`x`) records, which real registry
  images use for paths longer than 100 bytes. zstd is added in a later phase (optional NIF);
  gzip is native via Erlang's `:zlib`.

  Spec: [POSIX pax/ustar format](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/pax.html#tag_20_92_13_06).
  """

  alias Stevedore.Archive.Error

  @block 512
  @zero_block <<0::size(@block)-unit(8)>>

  @type entry :: %{
          name: String.t(),
          type: :regular | :directory | :symlink | :hardlink,
          mode: non_neg_integer(),
          size: non_neg_integer(),
          linkname: String.t() | nil,
          content: binary() | nil
        }

  @doc """
  Reads a tar archive into a list of entries, in archive order.

  ## Examples

      iex> tar = Stevedore.Archive.write!([%{name: "a.txt", type: :regular, mode: 0o644, size: 2, linkname: nil, content: "hi"}])
      iex> {:ok, [entry]} = Stevedore.Archive.read(tar)
      iex> {entry.name, entry.content}
      {"a.txt", "hi"}
  """
  @spec read(binary()) :: {:ok, [entry()]} | {:error, Error.t()}
  def read(tar) when is_binary(tar) do
    {:ok, read_blocks(tar, 0, %{}, [])}
  rescue
    error in Error -> {:error, error}
  end

  @doc """
  Writes entries to a tar archive (ustar). Raises `Stevedore.Archive.Error` on an unencodable
  entry (e.g. a path too long for ustar headers).

  ## Examples

      iex> tar = Stevedore.Archive.write!([%{name: "d", type: :directory, mode: 0o755, size: 0, linkname: nil, content: nil}])
      iex> {:ok, [entry]} = Stevedore.Archive.read(tar)
      iex> entry.type
      :directory
  """
  @spec write!([entry()]) :: binary()
  def write!(entries) when is_list(entries) do
    body = Enum.map(entries, &encode_entry/1)
    # Two zero blocks terminate the archive.
    IO.iodata_to_binary([body, @zero_block, @zero_block])
  end

  @doc """
  Writes entries to a tar archive, returning `{:ok, binary}` or an error tuple.

  ## Examples

      iex> {:ok, tar} = Stevedore.Archive.write([%{name: "a", type: :regular, mode: 0o644, size: 0, linkname: nil, content: ""}])
      iex> is_binary(tar)
      true
  """
  @spec write([entry()]) :: {:ok, binary()} | {:error, Error.t()}
  def write(entries) do
    {:ok, write!(entries)}
  rescue
    error in Error -> {:error, error}
  end

  @doc """
  Gzip-compresses `data` (RFC 1952).

  ## Examples

      iex> Stevedore.Archive.gunzip(Stevedore.Archive.gzip("payload"))
      {:ok, "payload"}
  """
  @spec gzip(iodata()) :: binary()
  def gzip(data), do: :zlib.gzip(data)

  @doc """
  Decompresses gzip `data`, returning `{:error, :gzip}` on malformed input.
  """
  @spec gunzip(binary()) :: {:ok, binary()} | {:error, :gzip}
  def gunzip(data) when is_binary(data) do
    {:ok, :zlib.gunzip(data)}
  rescue
    _ -> {:error, :gzip}
  end

  @doc """
  Whether zstd support is available — i.e. the optional `:ezstd` NIF is loaded. gzip is always
  available natively; zstd requires adding `{:ezstd, "~> 1.1"}` to your deps.
  """
  @spec zstd_available?() :: boolean()
  def zstd_available?, do: Code.ensure_loaded?(:ezstd)

  @doc """
  Zstd-compresses `data`. Raises a clear error if the optional `:ezstd` NIF isn't available.
  """
  @spec zstd(iodata()) :: binary()
  def zstd(data) do
    ensure_zstd!()
    apply(:ezstd, :compress, [IO.iodata_to_binary(data)])
  end

  @doc """
  Decompresses zstd `data`. Raises a clear error if the optional `:ezstd` NIF isn't available.
  """
  @spec unzstd(binary()) :: {:ok, binary()} | {:error, :zstd}
  def unzstd(data) when is_binary(data) do
    ensure_zstd!()

    case apply(:ezstd, :decompress, [data]) do
      decompressed when is_binary(decompressed) -> {:ok, decompressed}
      _ -> {:error, :zstd}
    end
  end

  @spec ensure_zstd!() :: :ok
  defp ensure_zstd! do
    unless zstd_available?() do
      raise RuntimeError,
            "zstd support requires the optional :ezstd dependency. Add {:ezstd, \"~> 1.1\"} to your deps."
    end

    :ok
  end

  # --- Reading ---

  # `pending` carries an `L`/`x` override (`:name`) for the immediately following header.
  @spec read_blocks(binary(), non_neg_integer(), map(), [entry()]) :: [entry()]
  defp read_blocks(tar, offset, _pending, acc) when byte_size(tar) - offset < @block do
    Enum.reverse(acc)
  end

  defp read_blocks(tar, offset, pending, acc) do
    header = binary_part(tar, offset, @block)

    if header == @zero_block do
      Enum.reverse(acc)
    else
      h = parse_header(header, offset)
      data_offset = offset + @block
      content = read_content(tar, data_offset, h.size, offset)
      next_offset = data_offset + padded(h.size)

      case h.typeflag do
        # GNU long name: the content is the name of the *next* entry.
        ?L ->
          read_blocks(tar, next_offset, Map.put(pending, :name, trim_nul(content)), acc)

        # PAX extended header: may carry a `path=` (and `size=`) override for the next entry.
        ?x ->
          read_blocks(tar, next_offset, merge_pax(pending, content), acc)

        _ ->
          name = Map.get(pending, :name, h.name)
          entry = build_entry(h, name, content)
          read_blocks(tar, next_offset, %{}, [entry | acc])
      end
    end
  end

  @spec parse_header(binary(), non_neg_integer()) :: map()
  defp parse_header(header, offset) do
    verify_checksum(header, offset)

    <<name::binary-size(100), mode::binary-size(8), _uid::binary-size(8), _gid::binary-size(8),
      size::binary-size(12), _mtime::binary-size(12), _chksum::binary-size(8), typeflag::8,
      linkname::binary-size(100), _magic::binary-size(6), _version::binary-size(2),
      _uname::binary-size(32), _gname::binary-size(32), _devmajor::binary-size(8),
      _devminor::binary-size(8), prefix::binary-size(155), _pad::binary>> = header

    %{
      name: join_prefix(trim_nul(prefix), trim_nul(name)),
      mode: parse_octal(mode),
      size: parse_octal(size),
      typeflag: typeflag,
      linkname: trim_nul(linkname)
    }
  end

  @spec read_content(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          binary()
  defp read_content(tar, data_offset, size, header_offset) do
    if data_offset + size > byte_size(tar) do
      raise Error, reason: :truncated, offset: header_offset
    end

    binary_part(tar, data_offset, size)
  end

  @spec build_entry(map(), String.t(), binary()) :: entry()
  defp build_entry(h, name, content) do
    type = type_from_flag(h.typeflag, name)

    %{
      name: name,
      type: type,
      mode: h.mode,
      size: h.size,
      linkname: if(type in [:symlink, :hardlink], do: h.linkname, else: nil),
      content: if(type == :regular, do: content, else: nil)
    }
  end

  @spec type_from_flag(byte(), String.t()) :: :regular | :directory | :symlink | :hardlink
  defp type_from_flag(flag, name) do
    case flag do
      ?0 -> :regular
      0 -> if String.ends_with?(name, "/"), do: :directory, else: :regular
      ?5 -> :directory
      ?2 -> :symlink
      ?1 -> :hardlink
      other -> raise Error, reason: "unsupported tar entry type #{inspect(<<other>>)}"
    end
  end

  @spec merge_pax(map(), binary()) :: map()
  defp merge_pax(pending, records) do
    records
    |> parse_pax_records()
    |> Enum.reduce(pending, fn
      {"path", value}, acc -> Map.put(acc, :name, value)
      _, acc -> acc
    end)
  end

  # PAX records are "<len> <key>=<value>\n", where <len> counts the whole record.
  @spec parse_pax_records(binary()) :: [{String.t(), String.t()}]
  defp parse_pax_records(records) do
    records
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, " ", parts: 2) do
        [_len, kv] ->
          case String.split(kv, "=", parts: 2) do
            [k, v] -> [{k, v}]
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  @spec verify_checksum(binary(), non_neg_integer()) :: :ok
  defp verify_checksum(header, offset) do
    <<before::binary-size(148), stored::binary-size(8), rest::binary>> = header
    stored_sum = parse_octal(stored)
    # The checksum is computed with the checksum field itself read as 8 spaces.
    computed = sum_bytes(before) + 8 * ?\s + sum_bytes(rest)

    if stored_sum == computed do
      :ok
    else
      raise Error, reason: :bad_checksum, offset: offset
    end
  end

  # --- Writing ---

  @spec encode_entry(entry()) :: iodata()
  defp encode_entry(entry) do
    content = entry_content(entry)
    size = byte_size(content)
    {name, prefix} = split_name(entry.name)

    header =
      [
        pad(name, 100),
        octal(entry.mode, 8),
        octal(0, 8),
        octal(0, 8),
        octal(size, 12),
        octal(0, 12),
        # checksum placeholder: 8 spaces while computing
        "        ",
        <<typeflag(entry.type)>>,
        pad(entry.linkname || "", 100),
        "ustar\0",
        "00",
        pad("", 32),
        pad("", 32),
        octal(0, 8),
        octal(0, 8),
        pad(prefix, 155),
        pad("", 12)
      ]
      |> IO.iodata_to_binary()

    header = put_checksum(header)
    [header, content, padding(size)]
  end

  @spec entry_content(entry()) :: binary()
  defp entry_content(%{type: :regular, content: content}) when is_binary(content), do: content
  defp entry_content(%{type: :regular}), do: ""
  defp entry_content(_), do: ""

  @spec typeflag(atom()) :: byte()
  defp typeflag(:regular), do: ?0
  defp typeflag(:directory), do: ?5
  defp typeflag(:symlink), do: ?2
  defp typeflag(:hardlink), do: ?1

  # Split a path into ustar name (<=100) + prefix (<=155) at a "/" boundary.
  @spec split_name(String.t()) :: {String.t(), String.t()}
  defp split_name(name) when byte_size(name) <= 100, do: {name, ""}

  defp split_name(name) do
    case split_at_slash(name) do
      {prefix, suffix} when byte_size(prefix) <= 155 and byte_size(suffix) <= 100 ->
        {suffix, prefix}

      _ ->
        raise Error, reason: "path too long for ustar header: #{name}"
    end
  end

  # Find the right-most "/" such that the suffix fits in 100 bytes.
  @spec split_at_slash(String.t()) :: {String.t(), String.t()} | :error
  defp split_at_slash(name) do
    name
    |> :binary.matches("/")
    |> Enum.map(&elem(&1, 0))
    |> Enum.reverse()
    |> Enum.find_value(:error, fn idx ->
      suffix = binary_part(name, idx + 1, byte_size(name) - idx - 1)
      if byte_size(suffix) <= 100, do: {binary_part(name, 0, idx), suffix}, else: nil
    end)
  end

  @spec put_checksum(binary()) :: binary()
  defp put_checksum(header) do
    sum = sum_bytes(header)
    # Canonical encoding: 6 octal digits, a NUL, then a space.
    field = String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, ?\s>>
    <<before::binary-size(148), _::binary-size(8), rest::binary>> = header
    before <> field <> rest
  end

  # --- Shared helpers ---

  @spec padded(non_neg_integer()) :: non_neg_integer()
  defp padded(size), do: size + padding_size(size)

  @spec padding(non_neg_integer()) :: binary()
  defp padding(size), do: <<0::size(padding_size(size))-unit(8)>>

  @spec padding_size(non_neg_integer()) :: non_neg_integer()
  defp padding_size(size), do: rem(@block - rem(size, @block), @block)

  @spec octal(non_neg_integer(), pos_integer()) :: binary()
  defp octal(value, width) do
    String.pad_leading(Integer.to_string(value, 8), width - 1, "0") <> <<0>>
  end

  @spec pad(binary(), pos_integer()) :: binary()
  defp pad(value, width) when byte_size(value) <= width do
    value <> <<0::size(width - byte_size(value))-unit(8)>>
  end

  @spec parse_octal(binary()) :: non_neg_integer()
  defp parse_octal(field) do
    case field |> trim_nul() |> String.trim() do
      "" -> 0
      digits -> String.to_integer(digits, 8)
    end
  end

  @spec trim_nul(binary()) :: binary()
  defp trim_nul(binary) do
    case :binary.split(binary, <<0>>) do
      [head | _] -> head
      [] -> binary
    end
  end

  @spec join_prefix(binary(), binary()) :: binary()
  defp join_prefix("", name), do: name
  defp join_prefix(prefix, name), do: prefix <> "/" <> name

  @spec sum_bytes(binary()) :: non_neg_integer()
  defp sum_bytes(binary), do: :binary.bin_to_list(binary) |> Enum.sum()
end
