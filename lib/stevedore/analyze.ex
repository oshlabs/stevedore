defmodule Stevedore.Analyze do
  @moduledoc """
  Inspect an image's effective filesystem: list files, read a file's bytes, and extract a
  best-effort software bill of materials — all over `Stevedore.Layer.merged_view/2`, in memory.

  `sbom/2` is a **heuristic**: it reads well-known metadata files (`/etc/os-release`, the dpkg
  and apk databases) if present. It does not run a scanner or shell out, and is not a guarantee
  of completeness.

  Spec: [OCI image-spec, layer](https://github.com/opencontainers/image-spec/blob/main/layer.md).
  """

  alias Stevedore.{Image, Layer}

  @type matcher :: Regex.t() | (String.t() -> boolean())

  @doc """
  Lists the effective-filesystem nodes whose path matches `matcher` (a `Regex` or a predicate),
  sorted by path.

  ## Examples

      iex> tar = Stevedore.Archive.write!([
      ...>   %{name: "usr/bin/sh", type: :regular, mode: 0o755, size: 1, linkname: nil, content: "x"},
      ...>   %{name: "etc/hosts", type: :regular, mode: 0o644, size: 1, linkname: nil, content: "y"}
      ...> ])
      iex> {:ok, image} = Stevedore.Build.image([tar], %{})
      iex> {:ok, nodes} = Stevedore.Analyze.files(image, ~r{^usr/})
      iex> Enum.map(nodes, & &1.path)
      ["usr/bin/sh"]
  """
  @spec files(Image.t(), matcher(), keyword()) :: {:ok, [Layer.fs_node()]} | {:error, term()}
  def files(%Image{} = image, matcher, _opts \\ []) do
    with {:ok, view} <- Layer.merged_view(image) do
      nodes =
        view
        |> Map.values()
        |> Enum.filter(&match_path?(matcher, &1.path))
        |> Enum.sort_by(& &1.path)

      {:ok, nodes}
    end
  end

  @doc """
  Reads the bytes of a single regular file from the effective filesystem (the top-most version
  across layers). Leading `/` in `path` is optional.
  """
  @spec read_file(Image.t(), String.t()) :: {:ok, binary()} | {:error, :enoent}
  def read_file(%Image{} = image, path) do
    target = normalize(path)

    with {:ok, entries} <- Layer.merged_entries(image) do
      case Enum.find(entries, &(normalize(&1.name) == target and &1.type == :regular)) do
        %{content: content} -> {:ok, content || ""}
        _ -> {:error, :enoent}
      end
    else
      _ -> {:error, :enoent}
    end
  end

  @doc """
  Best-effort SBOM: OS identity from `/etc/os-release` and installed packages from the dpkg
  (Debian/Ubuntu) and apk (Alpine) databases, if present.
  """
  @spec sbom(Image.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sbom(%Image{} = image, _opts \\ []) do
    with {:ok, entries} <- Layer.merged_entries(image) do
      files = Map.new(entries, fn entry -> {normalize(entry.name), entry.content} end)

      packages =
        parse_dpkg(files["var/lib/dpkg/status"]) ++ parse_apk(files["lib/apk/db/installed"])

      {:ok, %{"os" => parse_os_release(files["etc/os-release"]), "packages" => packages}}
    end
  end

  # --- matching ---

  defp match_path?(%Regex{} = regex, path), do: Regex.match?(regex, path)
  defp match_path?(fun, path) when is_function(fun, 1), do: fun.(path)

  # --- SBOM parsing ---

  @spec parse_os_release(binary() | nil) :: map() | nil
  defp parse_os_release(nil), do: nil

  defp parse_os_release(contents) do
    for line <- String.split(contents, "\n", trim: true),
        [key, value] <- [String.split(line, "=", parts: 2)],
        into: %{} do
      {key, value |> String.trim() |> String.trim("\"")}
    end
  end

  @spec parse_dpkg(binary() | nil) :: [map()]
  defp parse_dpkg(nil), do: []

  defp parse_dpkg(contents) do
    contents
    |> paragraphs()
    |> Enum.flat_map(fn fields ->
      case {fields["Package"], fields["Version"]} do
        {name, version} when is_binary(name) and is_binary(version) ->
          [%{"name" => name, "version" => version, "type" => "deb"}]

        _ ->
          []
      end
    end)
  end

  @spec parse_apk(binary() | nil) :: [map()]
  defp parse_apk(nil), do: []

  defp parse_apk(contents) do
    contents
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn record ->
      fields = apk_fields(record)

      case {fields["P"], fields["V"]} do
        {name, version} when is_binary(name) and is_binary(version) ->
          [%{"name" => name, "version" => version, "type" => "apk"}]

        _ ->
          []
      end
    end)
  end

  # Debian control-style paragraphs: "Key: value" lines, blank-line separated.
  defp paragraphs(contents) do
    contents
    |> String.split("\n\n", trim: true)
    |> Enum.map(fn paragraph ->
      for line <- String.split(paragraph, "\n", trim: true),
          [key, value] <- [String.split(line, ": ", parts: 2)],
          into: %{},
          do: {key, value}
    end)
  end

  # apk records: single-letter "K:value" lines.
  defp apk_fields(record) do
    for line <- String.split(record, "\n", trim: true),
        [key, value] <- [String.split(line, ":", parts: 2)],
        into: %{},
        do: {key, value}
  end

  # Canonical path: drop a leading "/" or "./" and any trailing "/".
  @spec normalize(String.t()) :: String.t()
  defp normalize(path) do
    path
    |> String.replace_prefix("/", "")
    |> String.replace_prefix("./", "")
    |> String.replace_suffix("/", "")
  end
end
