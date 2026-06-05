defmodule Stevedore.CLITest do
  # Mix.shell is global state, so these run synchronously.
  use ExUnit.Case, async: false

  alias Stevedore.{Archive, Build, CLI, Image}
  alias Stevedore.Transport.OCILayout

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    :ok
  end

  defp reg(name, content),
    do: %{
      name: name,
      type: :regular,
      mode: 0o644,
      size: byte_size(content),
      linkname: nil,
      content: content
    }

  defp seed(dir) do
    {:ok, image} = Build.image([Archive.write!([reg("f", "x")])], %{})
    {:ok, _} = Stevedore.copy(image, {%OCILayout{path: dir}, "v1"})
    image
  end

  describe "stevedore.copy" do
    @tag :tmp_dir
    test "copies between transports and prints the digest", %{tmp_dir: dir} do
      src = Path.join(dir, "src")
      dst = Path.join(dir, "dst")
      image = seed(src)

      Mix.Tasks.Stevedore.Copy.run(["oci:#{src}:v1", "oci:#{dst}:v1"])

      assert_received {:mix_shell, :info, [digest]}
      assert digest == to_string(Image.digest(image))
      assert {:ok, _} = OCILayout.get_manifest(%OCILayout{path: dst}, "v1")
    end

    test "a missing argument raises a Mix error" do
      assert_raise Mix.Error, ~r/usage/, fn -> Mix.Tasks.Stevedore.Copy.run(["only-one"]) end
    end

    test "an unknown --format raises" do
      assert_raise Mix.Error, ~r/format/, fn ->
        Mix.Tasks.Stevedore.Copy.run(["oci:./a", "oci:./b", "--format", "weird"])
      end
    end
  end

  describe "stevedore.inspect" do
    @tag :tmp_dir
    test "prints a manifest summary", %{tmp_dir: dir} do
      seed(dir)
      Mix.Tasks.Stevedore.Inspect.run(["oci:#{dir}:v1"])

      assert_received {:mix_shell, :info, ["Media-Type:" <> _]}
      assert_received {:mix_shell, :info, ["Digest:" <> _]}
      assert_received {:mix_shell, :info, ["Layers:      1"]}
    end

    @tag :tmp_dir
    test "--raw prints the raw manifest bytes", %{tmp_dir: dir} do
      image = seed(dir)
      Mix.Tasks.Stevedore.Inspect.run(["oci:#{dir}:v1", "--raw"])
      assert_received {:mix_shell, :info, [raw]}
      assert raw == image.manifest.raw
    end
  end

  describe "stevedore.list_tags / delete" do
    @tag :tmp_dir
    test "lists then deletes a tag", %{tmp_dir: dir} do
      seed(dir)

      Mix.Tasks.Stevedore.ListTags.run(["oci:#{dir}"])
      assert_received {:mix_shell, :info, ["v1"]}

      Mix.Tasks.Stevedore.Delete.run(["oci:#{dir}:v1"])
      assert_received {:mix_shell, :info, ["deleted" <> _]}
      assert {:ok, []} = OCILayout.list_tags(%OCILayout{path: dir})
    end
  end

  describe "stevedore.sync" do
    @tag :tmp_dir
    test "copies every job in the spec file", %{tmp_dir: dir} do
      src = Path.join(dir, "src")
      seed(src)
      spec = Path.join(dir, "sync.txt")

      File.write!(spec, """
      # mirror
      oci:#{src}:v1   oci:#{Path.join(dir, "a")}:v1
      oci:#{src}:v1   oci:#{Path.join(dir, "b")}:v1
      """)

      Mix.Tasks.Stevedore.Sync.run([spec])

      assert {:ok, _} = OCILayout.get_manifest(%OCILayout{path: Path.join(dir, "a")}, "v1")
      assert {:ok, _} = OCILayout.get_manifest(%OCILayout{path: Path.join(dir, "b")}, "v1")
    end
  end

  describe "CLI.format_error" do
    test "renders the common error shapes" do
      assert CLI.format_error({:bad_input, "nope"}) == "invalid input: nope"
      assert CLI.format_error(:not_found) == "not_found"
      assert CLI.format_error("boom") == "boom"

      assert CLI.format_error(%Stevedore.Registry.Error{
               reason: :unauthorized,
               registry: "r",
               repository: "x"
             }) =~ "registry error"
    end
  end
end
