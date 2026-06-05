defmodule Stevedore.ConfigTest do
  use ExUnit.Case, async: true

  alias Stevedore.Config

  doctest Config

  @sha "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  test "parses the full config surface" do
    raw = ~s({
      "architecture": "arm64", "os": "linux",
      "config": {"User": "1000", "WorkingDir": "/srv", "Cmd": ["sh"], "Env": ["A=1"],
                 "Labels": {"k": "v"}},
      "rootfs": {"type": "layers", "diff_ids": ["#{@sha}", "#{@sha}"]},
      "history": [{"created_by": "x"}]
    })

    assert {:ok, c} = Config.parse(raw)
    assert {c.architecture, c.os, c.user, c.working_dir} == {"arm64", "linux", "1000", "/srv"}
    assert {c.cmd, c.env, c.labels} == {["sh"], ["A=1"], %{"k" => "v"}}
    assert length(c.rootfs_diff_ids) == 2
    assert hd(c.rootfs_diff_ids).algorithm == :sha256
    assert c.history == [%{"created_by" => "x"}]
  end

  test "tolerates a minimal config with no inner config or rootfs" do
    assert {:ok, c} = Config.parse(~s({"architecture": "amd64", "os": "linux"}))
    assert c.rootfs_diff_ids == []
    assert c.entrypoint == nil
  end

  test "rejects a bad diff_id and non-object JSON" do
    assert {:error, {:bad_input, _}} =
             Config.parse(~s({"rootfs": {"diff_ids": ["not-a-digest"]}}))

    assert {:error, {:bad_input, _}} = Config.parse("[]")
  end
end
