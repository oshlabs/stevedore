defmodule Stevedore.ArchiveTest do
  use ExUnit.Case, async: true

  alias Stevedore.Archive

  doctest Archive

  defp entry(fields) do
    Map.merge(
      %{name: nil, type: :regular, mode: 0o644, size: 0, linkname: nil, content: nil},
      fields
    )
  end

  test "round-trips regular, directory, symlink, and hardlink entries" do
    entries = [
      entry(%{name: "hello.txt", type: :regular, mode: 0o644, size: 5, content: "hello"}),
      entry(%{name: "subdir", type: :directory, mode: 0o755}),
      entry(%{name: "link", type: :symlink, mode: 0o777, linkname: "hello.txt"}),
      entry(%{name: "hard", type: :hardlink, mode: 0o644, linkname: "hello.txt"})
    ]

    assert {:ok, decoded} = Archive.read(Archive.write!(entries))
    assert decoded == entries
  end

  test "round-trips a path longer than 100 bytes via the ustar prefix field" do
    name = String.duplicate("a", 60) <> "/" <> String.duplicate("b", 60)
    entries = [entry(%{name: name, type: :regular, mode: 0o644, size: 3, content: "abc"})]

    assert {:ok, [decoded]} = Archive.read(Archive.write!(entries))
    assert decoded.name == name
    assert decoded.content == "abc"
  end

  test "errors on a path too long for ustar headers" do
    name = String.duplicate("x", 300)
    assert {:error, %Archive.Error{}} = Archive.write([entry(%{name: name, type: :regular})])
  end

  test "errors on a truncated archive" do
    tar = Archive.write!([entry(%{name: "a.txt", type: :regular, size: 5, content: "hello"})])
    truncated = binary_part(tar, 0, 512 + 2)
    assert {:error, %Archive.Error{reason: :truncated}} = Archive.read(truncated)
  end

  test "gzip round-trips and gunzip reports malformed input" do
    assert Archive.gunzip(Archive.gzip("payload")) == {:ok, "payload"}
    assert Archive.gunzip("not gzip") == {:error, :gzip}
  end
end
