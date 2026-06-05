defmodule Stevedore.AnalyzeTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Analyze, Archive, Build}

  doctest Analyze

  defp reg(name, content),
    do: %{
      name: name,
      type: :regular,
      mode: 0o644,
      size: byte_size(content),
      linkname: nil,
      content: content
    }

  defp tar(entries), do: Archive.write!(entries)

  defp image(layers, config \\ %{}), do: Build.image(layers, config) |> elem(1)

  test "read_file returns the top-most version across layers" do
    img = image([tar([reg("etc/v", "one")]), tar([reg("etc/v", "two")])])
    assert {:ok, "two"} = Analyze.read_file(img, "/etc/v")
    assert {:ok, "two"} = Analyze.read_file(img, "etc/v")
    assert {:error, :enoent} = Analyze.read_file(img, "nope")
  end

  test "files filters the merged view by regex or predicate" do
    img = image([tar([reg("usr/bin/sh", "x"), reg("etc/hosts", "y"), reg("usr/lib/a", "z")])])

    assert {:ok, nodes} = Analyze.files(img, ~r{^usr/})
    assert Enum.map(nodes, & &1.path) == ["usr/bin/sh", "usr/lib/a"]

    assert {:ok, [%{path: "etc/hosts"}]} = Analyze.files(img, &String.starts_with?(&1, "etc/"))
  end

  test "sbom extracts os-release and dpkg/apk packages" do
    files = [
      reg("etc/os-release", ~s(NAME="Debian GNU/Linux"\nVERSION_ID="12"\n)),
      reg(
        "var/lib/dpkg/status",
        "Package: bash\nVersion: 5.2\n\nPackage: coreutils\nVersion: 9.1\n"
      ),
      reg("lib/apk/db/installed", "P:musl\nV:1.2.4\n\nP:busybox\nV:1.36.1\n")
    ]

    {:ok, sbom} = Analyze.sbom(image([tar(files)]))

    assert sbom["os"]["NAME"] == "Debian GNU/Linux"
    assert sbom["os"]["VERSION_ID"] == "12"
    assert %{"name" => "bash", "version" => "5.2", "type" => "deb"} in sbom["packages"]
    assert %{"name" => "musl", "version" => "1.2.4", "type" => "apk"} in sbom["packages"]
  end

  test "sbom is empty-but-shaped for an image with no metadata" do
    {:ok, sbom} = Analyze.sbom(image([tar([reg("bin/app", "x")])]))
    assert sbom == %{"os" => nil, "packages" => []}
  end
end
