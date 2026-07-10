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

  # Extracts the deckhand binary from a fresh runnable image into `dir`.
  defp extract_deckhand!(dir) do
    {:ok, image} = Testing.runnable_image()
    %{content: binary} = Enum.find(layer_entries(image), &(&1.name == "bin/deckhand"))

    bin = Path.join(dir, "deckhand")
    File.write!(bin, binary)
    File.chmod!(bin, 0o755)
    bin
  end

  @tag :tmp_dir
  test "the extracted deckhand binary serves its command set over HTTP", %{tmp_dir: dir} do
    bin = extract_deckhand!(dir)
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

    # sleep/true/false have HTTP parity; exit deliberately does not — a
    # remote peer must not be able to kill the container.
    assert {:ok, 200, ""} = http_get(http_port, "/sleep/0")
    assert {:ok, 200, ""} = http_get(http_port, "/true")
    assert {:ok, 200, ""} = http_get(http_port, "/false")
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

    # await-sig is applet-only: no HTTP path, no REPL command.
    assert {:ok, 404, _} = http_get(http_port, "/await-sig")
    true = Port.command(port, "await-sig\n")
    assert receive_until(port, "unknown command: await-sig")
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
    bin = extract_deckhand!(dir)
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

  test "runnable_image carries an applet symlink per command" do
    {:ok, image} = Testing.runnable_image()
    entries = Map.new(layer_entries(image), &{&1.name, &1})

    # Targets deliberately mix relative and absolute (extraction coverage).
    assert %{type: :symlink, linkname: "deckhand"} = entries["bin/cat"]
    assert %{type: :symlink, linkname: "/bin/deckhand"} = entries["bin/exit"]

    for name <-
          ~w(cat env id hostname uname ifaces mounts ls find ping ping6 resolve help sleep exit true false await-sig) do
      assert %{type: :symlink} = entries["bin/" <> name]
    end
  end

  @tag :tmp_dir
  test "applets run to completion", %{tmp_dir: dir} do
    bin = extract_deckhand!(dir)

    probe = Path.join(dir, "probe")
    File.write!(probe, "cargo\n")
    assert {"cargo\n", 0} = System.cmd(bin, ["cat", probe])

    # `cat` without a path echoes stdin until EOF (sh here only builds the pipe).
    assert {"stow\naway\n", 0} =
             System.cmd("sh", ["-c", "printf 'stow\\naway\\n' | '#{bin}' cat"])

    assert {"", 3} = System.cmd(bin, ["exit", "3"])
    assert {"", 0} = System.cmd(bin, ["sleep", "0"])
    assert {"", 0} = System.cmd(bin, ["true"])
    assert {"", 1} = System.cmd(bin, ["false"])

    assert {out, 0} = System.cmd(bin, ["env"], env: [{"DECKHAND_APPLET_TEST", "aye"}])
    assert out =~ "DECKHAND_APPLET_TEST=aye\n"

    # The diagnostics commands are applets too — same output as the REPL.
    assert {uname, 0} = System.cmd(bin, ["uname"])
    assert uname =~ "Linux"
    assert {mounts, 0} = System.cmd(bin, ["mounts"])
    assert mounts =~ " / "
    assert {help, 0} = System.cmd(bin, ["help"])
    assert help =~ "deckhand"
  end

  @tag :tmp_dir
  test "argv[0] dispatch works through a real symlink", %{tmp_dir: dir} do
    bin = extract_deckhand!(dir)
    {:ok, nodename} = :inet.gethostname()

    link = Path.join(dir, "hostname")
    File.ln_s!(bin, link)
    assert {out, 0} = System.cmd(link, [])
    assert out == "#{nodename}\n"

    false_link = Path.join(dir, "false")
    File.ln_s!(bin, false_link)
    assert {"", 1} = System.cmd(false_link, [])
  end

  @tag :tmp_dir
  test "PORT/applet disambiguation: digits boot the server, names run applets",
       %{tmp_dir: dir} do
    bin = extract_deckhand!(dir)

    # A name runs the applet: exact output, no banner, no prompt, no events.
    {:ok, nodename} = :inet.gethostname()
    assert {out, 0} = System.cmd(bin, ["hostname"])
    assert out == "#{nodename}\n"

    # An unknown name is neither PORT nor applet: usage, exit 2.
    assert {_, 2} = System.cmd(bin, ["bogus"])

    # An all-digits first arg still means PORT: REPL + server boot unchanged.
    http_port = free_test_port()
    port = Port.open({:spawn_executable, bin}, [:binary, args: [to_string(http_port)]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true) end)

    assert_receive {^port, {:data, "deckhand aboard.\n" <> _}}, 2_000
    assert {:ok, 200, _} = http_get(http_port, "/hostname")
  end

  @tag :tmp_dir
  test "await-sig blocks until any signal, prints its details, and exits", %{tmp_dir: dir} do
    bin = extract_deckhand!(dir)

    port = Port.open({:spawn_executable, bin}, [:binary, :exit_status, args: ["await-sig"]])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    :ok = await_signals_blocked(os_pid)
    {_, 0} = System.cmd("kill", ["-USR1", to_string(os_pid)])

    # The one line — with the signal's details — is the whole output.
    assert_receive {^port, {:data, line}}, 2_000
    assert line =~ ~r/^event: signal USR1 \(10\) code=0 pid=\d+ uid=\d+\n$/
    assert_receive {^port, {:exit_status, 0}}, 2_000

    # TERM is reported and exits 0 — not killed by the default disposition.
    port2 = Port.open({:spawn_executable, bin}, [:binary, :exit_status, args: ["await-sig"]])
    {:os_pid, os_pid2} = Port.info(port2, :os_pid)
    :ok = await_signals_blocked(os_pid2)
    {_, 0} = System.cmd("kill", ["-TERM", to_string(os_pid2)])
    assert receive_until(port2, "event: signal TERM (15)")
    assert_receive {^port2, {:exit_status, 0}}, 2_000

    # Any argument is a usage error.
    assert {_, 2} = System.cmd(bin, ["await-sig", "8080"])
  end

  # await-sig's first act is blocking every signal; poll /proc until that
  # mask is visible, so the kill below lands after signalfd is armed (before
  # it, the default disposition would terminate the process).
  defp await_signals_blocked(os_pid, attempts \\ 100) do
    blocked =
      with {:ok, status} <- File.read("/proc/#{os_pid}/status"),
           [hex] <- Regex.run(~r/^SigBlk:\s*(\S+)$/m, status, capture: :all_but_first) do
        String.to_integer(hex, 16) > 0
      else
        _ -> false
      end

    cond do
      blocked ->
        :ok

      attempts == 0 ->
        {:error, :signals_never_blocked}

      true ->
        Process.sleep(10)
        await_signals_blocked(os_pid, attempts - 1)
    end
  end

  @tag :tmp_dir
  test "the REPL propagates `exit N` as the process exit status", %{tmp_dir: dir} do
    bin = extract_deckhand!(dir)

    port =
      Port.open({:spawn_executable, bin}, [
        :binary,
        :exit_status,
        args: [to_string(free_test_port())]
      ])

    assert_receive {^port, {:data, "deckhand aboard.\n" <> _}}, 2_000
    true = Port.command(port, "exit 7\n")
    assert receive_until(port, "going ashore.")
    assert_receive {^port, {:exit_status, 7}}, 2_000
  end

  test "two registries run concurrently" do
    other = Testing.start_registry!()
    on_exit(fn -> File.rm_rf!(other.store) end)

    {:ok, image} = Testing.synthetic_image()
    assert Testing.push!(other, image, "x/y:z") =~ "#{other.port}/x/y:z"
    refute other.port == 0
  end
end
