defmodule Stevedore.Transport.ParseTest do
  use ExUnit.Case, async: true

  alias Stevedore.Transport
  alias Stevedore.Transport.Parse

  doctest Parse

  test "docker:// builds a Registry transport and the tag/digest ref" do
    assert {:ok,
            {%Transport.Registry{registry: "registry-1.docker.io", repository: "library/alpine"},
             "3.20"}} =
             Parse.parse("docker://alpine:3.20")

    assert {:ok, {%Transport.Registry{}, %Stevedore.Digest{}}} =
             Parse.parse(
               "docker://ghcr.io/o/r@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
             )
  end

  test "oci: and oci-archive: with and without a ref" do
    assert {:ok, {%Transport.OCILayout{path: "./out"}, "3.20"}} = Parse.parse("oci:./out:3.20")
    assert {:ok, {%Transport.OCILayout{path: "./out"}, nil}} = Parse.parse("oci:./out")

    assert {:ok, {%Transport.Archive{path: "i.tar", format: :oci}, "v1"}} =
             Parse.parse("oci-archive:i.tar:v1")
  end

  test "docker-archive: and dir: and static:" do
    assert {:ok, {%Transport.Archive{path: "i.tar", format: :docker}, nil}} =
             Parse.parse("docker-archive:i.tar")

    assert {:ok, {%Transport.Dir{path: "./d"}, nil}} = Parse.parse("dir:./d")
    assert {:ok, {%Transport.Static{path: "./pub"}, "v1"}} = Parse.parse("static:./pub:v1")
  end

  test "archive transports get a fresh work dir" do
    assert {:ok, {%Transport.Archive{work: w1}, _}} = Parse.parse("oci-archive:a.tar")
    assert {:ok, {%Transport.Archive{work: w2}, _}} = Parse.parse("oci-archive:a.tar")
    assert is_binary(w1) and w1 != w2
  end

  test "unknown transport is rejected" do
    assert {:error, {:bad_input, _}} = Parse.parse("ftp://nope")
  end
end
