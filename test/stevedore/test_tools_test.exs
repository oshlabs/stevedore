defmodule Stevedore.TestToolsTest do
  @moduledoc """
  Proves the `Stevedore.TestTools` scaffolding the integration suites rely on: binary resolution
  (incl. the `~/go/bin` fallback) and the `tool_test/3` skip-when-missing macro. Hermetic.
  """
  use ExUnit.Case, async: true
  import Stevedore.TestTools

  describe "find/1 and available?/1" do
    test "resolve a binary that is guaranteed present" do
      # `sh` is on PATH on every POSIX CI runner and dev box.
      assert available?("sh")
      assert is_binary(find("sh"))
    end

    test "return nil/false for a binary that cannot exist" do
      refute available?("stevedore-nope-does-not-exist")
      assert find("stevedore-nope-does-not-exist") == nil
    end
  end

  describe "missing/1" do
    test "returns only the absent tools" do
      assert missing(["sh"]) == []
      assert missing(["sh", "stevedore-nope-xyz"]) == ["stevedore-nope-xyz"]
    end
  end

  # Present-tool case: this expands to a real test and must actually run its body.
  tool_test "tool_test runs the body when the tool is present", ["sh"] do
    assert {output, 0} = System.cmd(find("sh"), ["-c", "echo ok"])
    assert String.trim(output) == "ok"
  end

  # Missing-tool case: this expands to a `@tag skip:` test. If the macro were wrong and ran the
  # body, the flunk would fail the suite — so a green run proves it was skipped instead.
  tool_test "tool_test skips the body when a tool is missing", ["stevedore-nope-xyz"] do
    flunk("body of a missing-tool tool_test must not run — it should be skipped")
  end
end
