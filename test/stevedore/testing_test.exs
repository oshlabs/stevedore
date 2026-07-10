defmodule Stevedore.TestingTest do
  # Boots real Bandit listeners; not async (binds ports).
  use ExUnit.Case, async: false

  alias Stevedore.Testing
  alias Stevedore.Transport.OCILayout

  @moduletag :tmp_dir

  setup %{} do
    reg = Testing.start_registry!()
    on_exit(fn -> File.rm_rf!(reg.store) end)
    %{reg: reg}
  end

  test "synthetic image round-trips through the test registry", %{reg: reg, tmp_dir: dir} do
    {:ok, image} = Testing.synthetic_image()
    ref = Testing.push!(reg, image, "lib/app:v1")
    assert ref == "#{reg.registry}/lib/app:v1"

    # Pull it back over plain HTTP; the manifest digest is unchanged.
    dst = %OCILayout{path: Path.join(dir, "dst")}

    assert {:ok, %{digest: digest}} =
             Stevedore.copy("docker://" <> ref, {dst, "v1"}, scheme: "http")

    assert digest == Stevedore.manifest_digest(image.manifest.raw)
  end

  test "the default synthetic image carries the tricky tar shapes" do
    {:ok, image} = Testing.synthetic_image()

    # One layer whose tar holds dirs, regular files, and an absolute symlink.
    entries = Map.new(layer_entries(image), &{&1.name, &1})

    assert %{type: :directory} = entries["etc"]
    assert %{type: :regular, content: "synthetic\n"} = entries["etc/stevedore-test"]
    assert %{type: :symlink, linkname: "/bin/busybox"} = entries["bin/sh"]
  end

  test "contents and config are overridable" do
    {:ok, image} =
      Testing.synthetic_image(
        files: %{"hello" => "world"},
        symlinks: %{},
        config: %{cmd: ["/hello"], env: ["A=1"]}
      )

    assert Enum.map(layer_entries(image), & &1.name) == ["hello"]
    assert image.config.cmd == ["/hello"]
    assert image.config.env == ["A=1"]
  end

  defp layer_entries(image) do
    [layer] = image.layers

    {:ok, entries} =
      image.blobs
      |> Map.fetch!(to_string(layer.digest))
      |> :zlib.gunzip()
      |> Stevedore.Archive.read()

    entries
  end

  test "runnable_image layers the deckhand binary with an exec entrypoint" do
    {:ok, image} = Testing.runnable_image()
    entries = Map.new(layer_entries(image), &{&1.name, &1})

    assert %{type: :regular, mode: 0o755} = entries["bin/deckhand"]
    assert %{type: :regular, content: "synthetic\n"} = entries["etc/stevedore-test"]
    assert image.config.entrypoint == ["/bin/deckhand"]
    assert image.config.cmd == []
    assert image.config.os == "linux"
  end

  @tag :tmp_dir
  test "runnable_image round-trips through the registry", %{reg: reg, tmp_dir: dir} do
    {:ok, image} = Testing.runnable_image()
    ref = Testing.push!(reg, image, "lib/runnable:v1")

    dst = %OCILayout{path: Path.join(dir, "dst")}

    assert {:ok, %{digest: digest}} =
             Stevedore.copy("docker://" <> ref, {dst, "v1"}, scheme: "http")

    assert digest == Stevedore.manifest_digest(image.manifest.raw)
  end

  @tag :tmp_dir
  test "platforms: :all yields a pushable index that resolves per platform",
       %{reg: reg, tmp_dir: dir} do
    {:ok, index} = Testing.runnable_image(platforms: :all)

    assert [%{config: %{architecture: "amd64"}}, %{config: %{architecture: "arm64"}}] =
             index.images

    # Push the whole index, pull back a single platform.
    ref = "#{reg.registry}/lib/runnable:multi"
    {:ok, _} = Stevedore.copy(index, "docker://" <> ref, all: true, scheme: "http")

    dst = %OCILayout{path: Path.join(dir, "dst")}

    assert {:ok, %{digest: digest}} =
             Stevedore.copy("docker://" <> ref, {dst, "arm"},
               platform: "linux/arm64",
               scheme: "http"
             )

    [arm] = Enum.filter(index.images, &(&1.config.architecture == "arm64"))
    assert digest == Stevedore.Image.digest(arm)
  end

  @tag :tmp_dir
  test "the extracted deckhand binary serves its command set over HTTP", %{tmp_dir: dir} do
    {:ok, image} = Testing.runnable_image()
    %{content: binary} = Enum.find(layer_entries(image), &(&1.name == "bin/deckhand"))

    bin = Path.join(dir, "deckhand")
    File.write!(bin, binary)
    File.chmod!(bin, 0o755)

    http_port = free_test_port()
    port = Port.open({:spawn_executable, bin}, [:binary, args: [to_string(http_port)]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true) end)

    assert_receive {^port, {:data, "deckhand aboard.\n" <> _}}, 2_000

    # The REPL answers on stdin...
    true = Port.command(port, "hostname\n")
    {:ok, nodename} = :inet.gethostname()
    expected = to_string(nodename)
    assert receive_until(port, expected)

    # ...and the HTTP frontend mirrors the same command, plus 404 with help.
    assert {:ok, 200, body} = http_get(http_port, "/hostname")
    assert body =~ expected
    assert {:ok, 200, body} = http_get(http_port, "/id")
    assert body =~ "uid="
    assert {:ok, 404, body} = http_get(http_port, "/exit")
    assert body =~ "help"

    # cat/ls/find mirror the rootfs probes (here against the host fs).
    probe = Path.join(dir, "probe")
    File.write!(probe, "cargo\n")
    assert {:ok, 200, "cargo\n"} = http_get(http_port, "/cat" <> probe)
    assert {:ok, 200, ls} = http_get(http_port, "/ls" <> dir)
    assert ls =~ "probe\n"
    assert {:ok, 200, found} = http_get(http_port, "/find" <> dir)
    assert found =~ probe

    # Every request also surfaced as a console event.
    assert receive_until(port, "event: GET /hostname from")
  end

  # Port data arrives in arbitrary chunks; accumulate until `needle` shows up.
  defp receive_until(port, needle, acc \\ "") do
    receive do
      {^port, {:data, data}} ->
        acc = acc <> data
        if acc =~ needle, do: true, else: receive_until(port, needle, acc)
    after
      2_000 -> flunk("expected #{inspect(needle)} in output, got: #{inspect(acc)}")
    end
  end

  defp free_test_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp http_get(port, path, attempts \\ 20) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 500) do
      {:ok, sock} ->
        :ok = :gen_tcp.send(sock, "GET #{path} HTTP/1.1\r\nHost: test\r\n\r\n")
        response = recv_all(sock, "")
        :gen_tcp.close(sock)
        ["HTTP/1.1 " <> status_line | _] = String.split(response, "\r\n")
        [status | _] = String.split(status_line, " ")
        [_head, body] = String.split(response, "\r\n\r\n", parts: 2)
        {:ok, String.to_integer(status), body}

      {:error, :econnrefused} when attempts > 0 ->
        # The binary is still booting its listeners; retry briefly.
        Process.sleep(50)
        http_get(port, path, attempts - 1)
    end
  end

  @tag :tmp_dir
  test "a second deckhand on a taken port runs REPL-only", %{tmp_dir: dir} do
    {:ok, image} = Testing.runnable_image()
    %{content: binary} = Enum.find(layer_entries(image), &(&1.name == "bin/deckhand"))

    bin = Path.join(dir, "deckhand")
    File.write!(bin, binary)
    File.chmod!(bin, 0o755)

    http_port = free_test_port()
    first = Port.open({:spawn_executable, bin}, [:binary, args: [to_string(http_port)]])
    {:os_pid, first_pid} = Port.info(first, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-KILL", to_string(first_pid)], stderr_to_stdout: true) end)
    assert_receive {^first, {:data, "deckhand aboard.\n" <> _}}, 2_000
    # The listener must be live before the second instance races it.
    assert {:ok, 200, _} = http_get(http_port, "/id")

    second = Port.open({:spawn_executable, bin}, [:binary, args: [to_string(http_port)]])
    {:os_pid, second_pid} = Port.info(second, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-KILL", to_string(second_pid)], stderr_to_stdout: true)
    end)

    assert receive_until(second, "REPL-only, webserver disabled")

    # The second instance's REPL still answers; the first still serves HTTP.
    true = Port.command(second, "id\n")
    assert receive_until(second, "uid=")
    assert {:ok, 200, _} = http_get(http_port, "/id")
  end

  # The server sends Connection: close, so read until the peer closes.
  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, :closed} -> acc
    end
  end

  test "two registries run concurrently" do
    other = Testing.start_registry!()
    on_exit(fn -> File.rm_rf!(other.store) end)

    {:ok, image} = Testing.synthetic_image()
    assert Testing.push!(other, image, "x/y:z") =~ "#{other.port}/x/y:z"
    refute other.port == 0
  end
end
