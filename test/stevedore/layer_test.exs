defmodule Stevedore.LayerTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Archive, Layer}

  doctest Layer

  defp reg(name, content),
    do: %{
      name: name,
      type: :regular,
      mode: 0o644,
      size: byte_size(content),
      linkname: nil,
      content: content
    }

  defp dir(name),
    do: %{name: name, type: :directory, mode: 0o755, size: 0, linkname: nil, content: nil}

  defp wh(name),
    do: %{name: name, type: :regular, mode: 0o644, size: 0, linkname: nil, content: ""}

  defp layer(entries), do: Archive.gzip(Archive.write!(entries))

  describe "entries/2" do
    test "decodes a gzip layer and a raw tar (by sniffing)" do
      tar = Archive.write!([reg("f", "x")])
      assert {:ok, [%{name: "f"}]} = Layer.entries(Archive.gzip(tar))
      assert {:ok, [%{name: "f"}]} = Layer.entries(tar)
    end
  end

  describe "merged_view/2 — whiteouts and opaque dirs" do
    setup do
      l0 =
        layer([
          reg("a", "A"),
          dir("dir/"),
          reg("dir/x", "X"),
          reg("dir/y", "Y"),
          reg("keep", "K0")
        ])

      l1 = layer([wh(".wh.a"), reg("keep", "K1"), reg("b", "B")])
      l2 = layer([wh("dir/.wh..wh..opq"), reg("dir/z", "Z")])
      {:ok, view} = Layer.merged_view([l0, l1, l2])
      %{view: view}
    end

    test "applies regular whiteouts, opaque dirs, and overrides", %{view: view} do
      # a deleted (.wh.a); dir/x, dir/y hidden by opaque; dir/z added; dir node kept.
      assert view |> Map.keys() |> Enum.sort() == ["b", "dir", "dir/z", "keep"]
    end

    test "records provenance (from_layer) of the surviving entry", %{view: view} do
      assert view["keep"].from_layer == 1
      assert view["dir/z"].from_layer == 2
      assert view["b"].from_layer == 1
    end

    test "keeps the opaque directory itself as a directory node", %{view: view} do
      assert view["dir"].type == :directory
    end
  end

  describe "diff/3" do
    test "reports added, removed, and modified paths" do
      a = Archive.write!([reg("keep", "K"), reg("old", "O")])
      b = Archive.write!([reg("keep", "K2"), reg("new", "N")])

      assert {:ok, %{added: ["new"], removed: ["old"], modified: ["keep"]}} = Layer.diff(a, b)
    end
  end

  describe "merged_entries/2" do
    test "returns the effective files as sorted tar entries with content" do
      l0 = layer([reg("a", "A"), reg("b", "B0")])
      l1 = layer([reg("b", "B1"), wh(".wh.a")])

      assert {:ok, [entry]} = Layer.merged_entries([l0, l1])
      assert entry.name == "b"
      assert entry.content == "B1"
    end
  end
end
