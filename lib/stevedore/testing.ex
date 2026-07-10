defmodule Stevedore.Testing do
  @moduledoc """
  Test-support helpers: a hermetic local registry plus synthetic images, so a
  test suite — this library's own, or a dependent's (Tank) — exercises real
  push/pull mechanics over HTTP with **zero external network**: no Docker Hub,
  no rate limits, no flakes.

  Lives in `lib/` (not `test/support`) so dependents can use it, following the
  `Oban.Testing`/`Plug.Test` idiom. It costs nothing unless called;
  `start_registry!/1` needs the optional `:plug` and `:bandit` dependencies,
  exactly like `Stevedore.Server` (a dependent adds them `only: :test`).

  ## Example (inside ExUnit)

      reg = Stevedore.Testing.start_registry!()
      {:ok, image} = Stevedore.Testing.synthetic_image()
      ref = Stevedore.Testing.push!(reg, image, "tank/test:latest")
      #=> "localhost:49321/tank/test:latest" — pull it over plain HTTP
      #   (pass `scheme: "http"` to Stevedore calls; clients following
      #   Docker's localhost-is-insecure convention need nothing).

  The server is **linked to the caller**, so under ExUnit its lifetime is the
  test's. The store directory is returned in the registry map; pass `:store`
  to control it, or clean the returned path in `on_exit`.
  """

  alias Stevedore.{Archive, Build}

  @typedoc "A running test registry: its `host:port` ref prefix, port, store dir, and pid."
  @type registry :: %{
          registry: String.t(),
          port: :inet.port_number(),
          store: Path.t(),
          pid: pid()
        }

  @doc """
  Starts a registry server on a free localhost port, linked to the caller.

  Options: `:store` (filesystem root; default a fresh tmp dir), `:authorize`
  (default: allow everything — it's a test registry). Each instance gets its
  own uploads process, so multiple registries can run concurrently.
  """
  @spec start_registry!(keyword()) :: registry()
  def start_registry!(opts \\ []) do
    port = free_port()

    store =
      Keyword.get_lazy(opts, :store, fn ->
        Path.join(
          System.tmp_dir!(),
          "stevedore-test-registry-#{System.unique_integer([:positive])}"
        )
      end)

    {:ok, pid} =
      Stevedore.Server.start_link(
        store: store,
        port: port,
        authorize: Keyword.get(opts, :authorize, fn _conn, _action, _scope -> :ok end),
        uploads: :"stevedore_testing_uploads_#{port}"
      )

    %{registry: "localhost:#{port}", port: port, store: store, pid: pid}
  end

  @doc """
  Builds a small deterministic image entirely in memory.

  The default contents are chosen to exercise the extraction cases naive tar
  handling gets wrong: a marker file (`etc/stevedore-test`), a fake
  `bin/busybox`, and `bin/sh` as a **symlink with an absolute target**.

  Options: `:files` (`%{"path" => "content"}`), `:symlinks`
  (`%{"path" => "target"}`), `:config` (the `Stevedore.Build` config map,
  default `%{cmd: ["/bin/sh"]}`). Parent directories are emitted
  automatically.
  """
  @spec synthetic_image(keyword()) :: {:ok, Stevedore.Image.t()} | {:error, term()}
  def synthetic_image(opts \\ []) do
    files =
      Keyword.get(opts, :files, %{
        "etc/stevedore-test" => "synthetic\n",
        "bin/busybox" => "#!/bin/true\n"
      })

    symlinks = Keyword.get(opts, :symlinks, %{"bin/sh" => "/bin/busybox"})
    config = Keyword.get(opts, :config, %{cmd: ["/bin/sh"]})

    entries =
      dir_entries(Map.keys(files) ++ Map.keys(symlinks)) ++
        Enum.map(Enum.sort(files), fn {name, content} ->
          %{
            name: name,
            type: :regular,
            mode: 0o644,
            size: byte_size(content),
            linkname: nil,
            content: content
          }
        end) ++
        Enum.map(Enum.sort(symlinks), fn {name, target} ->
          %{name: name, type: :symlink, mode: 0o777, size: 0, linkname: target, content: nil}
        end)

    Build.image([Archive.write!(entries)], config)
  end

  @doc """
  Builds a small deterministic image whose contents actually **run**: the
  bundled `deckhand` binary (statically linked, libc-free, ~25 KB; source,
  pinned-Zig `build.sh`, and CI byte-diff guard in `priv/deckhand/`) layered
  at `/bin/deckhand`, plus the `etc/stevedore-test` marker file.

  deckhand is a container diagnostic: an event-printing REPL (console
  resizes, signals, HTTP hits — and it runs until signaled, so it doubles as
  the keepalive process) plus a GET-only web server on 0.0.0.0/:: (default
  port 8080) whose URL space mirrors the command set — `/env`, `/id`,
  `/hostname`, `/uname`, `/ifaces`, `/mounts`, `/cat/PATH`, `/ls/PATH`,
  `/find/PATH`, `/ping/H`, `/ping6/H`,
  `/resolve/N` — so tests can inspect the container's view of its world from
  outside. See `priv/deckhand/README.md`.

  The layer also carries busybox-style **applet symlinks** — one per command
  (`/bin/cat`, `/bin/env`, `/bin/id`, `/bin/hostname`, `/bin/uname`,
  `/bin/ifaces`, `/bin/mounts`, `/bin/ls`, `/bin/find`, `/bin/ping`,
  `/bin/ping6`, `/bin/resolve`, `/bin/help`, `/bin/sleep`, `/bin/exit`,
  `/bin/true`, `/bin/false` → `deckhand`); argv[0] dispatch runs that
  command to completion — plain stdout, no banner, exit 0 or the applet's
  code — covering the run-to-completion process shapes
  (`command: ["/bin/exit", "3"]`, `["/bin/sleep", "3"]`, `/bin/cat` echoing
  stdin on a tty) that would otherwise need a distro image. One applet has
  no REPL/HTTP counterpart: `/bin/await-sig` blocks until **any** signal
  arrives, prints its details as one line — name, number, si_code, sender
  pid/uid, and for SIGWINCH the new console size — and exits 0. That one
  line is its only output, so a test can assert signal (or PTY-resize)
  delivery from outside verbatim.

  With no options the image targets the host platform and its config is
  `%{entrypoint: ["/bin/deckhand"], cmd: []}`.

  Options: `:platforms` (`:all` builds linux/amd64 **and** linux/arm64 under
  a real OCI index — returns `{:ok, Stevedore.Index.t()}` — so consumers can
  hermetically exercise index → platform-manifest resolution), `:config`
  (overrides the `Stevedore.Build` config map).
  """
  @spec runnable_image(keyword()) ::
          {:ok, Stevedore.Image.t() | Stevedore.Index.t()} | {:error, term()}
  def runnable_image(opts \\ []) do
    case Keyword.get(opts, :platforms, :host) do
      :host ->
        with {:ok, arch} <- host_arch(), do: build_runnable(arch, opts)

      :all ->
        with {:ok, amd} <- build_runnable("amd64", opts),
             {:ok, arm} <- build_runnable("arm64", opts) do
          Build.index([amd, arm])
        end
    end
  end

  @doc """
  Pushes `image` (a built `Stevedore.Image`) to the test registry under
  `name_tag` (e.g. `"tank/test:latest"`); returns the full pullable ref
  (`"localhost:PORT/tank/test:latest"`).
  """
  @spec push!(registry(), Stevedore.Image.t(), String.t()) :: String.t()
  def push!(%{registry: registry}, image, name_tag) do
    ref = "#{registry}/#{name_tag}"
    {:ok, _} = Stevedore.copy(image, "docker://" <> ref, scheme: "http")
    ref
  end

  @spec build_runnable(String.t(), keyword()) :: {:ok, Stevedore.Image.t()} | {:error, term()}
  defp build_runnable(oci_arch, opts) do
    bin_path = "bin/deckhand"
    config = Keyword.get(opts, :config, %{entrypoint: ["/" <> bin_path], cmd: []})
    marker = "etc/stevedore-test"

    with {:ok, binary} <- File.read(deckhand_path(oci_arch)) do
      # The runtime skeleton every real image ships: mount points for
      # /proc,/dev,/sys (+ /tmp,/run), and the /etc files runtimes bind-mount
      # over (resolv.conf, hosts, hostname). Without these, a runtime that
      # mounts onto existing paths — as Tank's does — fails with ENOENT.
      skeleton_dirs =
        Enum.map(
          ~w(proc dev sys tmp run),
          &%{name: &1, type: :directory, mode: 0o755, size: 0, linkname: nil, content: nil}
        )

      skeleton_files =
        Enum.map(
          ~w(etc/resolv.conf etc/hosts etc/hostname),
          &%{name: &1, type: :regular, mode: 0o644, size: 0, linkname: nil, content: ""}
        )

      # Busybox-style applet symlinks — argv[0] dispatch in the binary runs
      # that command to completion (see priv/deckhand/README.md); every
      # deckhand command is an applet. Targets deliberately mix relative and
      # absolute: both must extract correctly, so the split adds coverage
      # for free.
      applet_links =
        %{
          "bin/cat" => "deckhand",
          "bin/env" => "deckhand",
          "bin/id" => "deckhand",
          "bin/hostname" => "deckhand",
          "bin/ls" => "deckhand",
          "bin/uname" => "deckhand",
          "bin/ifaces" => "deckhand",
          "bin/mounts" => "deckhand",
          "bin/help" => "deckhand",
          "bin/find" => "/bin/deckhand",
          "bin/sleep" => "/bin/deckhand",
          "bin/exit" => "/bin/deckhand",
          "bin/true" => "/bin/deckhand",
          "bin/false" => "/bin/deckhand",
          "bin/ping" => "/bin/deckhand",
          "bin/ping6" => "/bin/deckhand",
          "bin/resolve" => "/bin/deckhand",
          "bin/await-sig" => "/bin/deckhand"
        }
        |> Enum.sort()
        |> Enum.map(fn {name, target} ->
          %{name: name, type: :symlink, mode: 0o777, size: 0, linkname: target, content: nil}
        end)

      entries =
        dir_entries([marker, bin_path]) ++
          skeleton_dirs ++
          skeleton_files ++
          applet_links ++
          [
            %{
              name: bin_path,
              type: :regular,
              mode: 0o755,
              size: byte_size(binary),
              linkname: nil,
              content: binary
            },
            %{
              name: marker,
              type: :regular,
              mode: 0o644,
              size: byte_size("synthetic\n"),
              linkname: nil,
              content: "synthetic\n"
            }
          ]

      Build.image([Archive.write!(entries)], config, platform: "linux/#{oci_arch}")
    end
  end

  @spec deckhand_path(String.t()) :: Path.t()
  defp deckhand_path(oci_arch) do
    file =
      case oci_arch do
        "amd64" -> "deckhand-x86_64"
        "arm64" -> "deckhand-aarch64"
      end

    Path.join([:code.priv_dir(:stevedore), "deckhand", file])
  end

  @spec host_arch() :: {:ok, String.t()} | {:error, {:unsupported_arch, String.t()}}
  defp host_arch do
    arch = List.to_string(:erlang.system_info(:system_architecture))

    cond do
      String.starts_with?(arch, ["x86_64", "amd64"]) -> {:ok, "amd64"}
      String.starts_with?(arch, ["aarch64", "arm64"]) -> {:ok, "arm64"}
      true -> {:error, {:unsupported_arch, arch}}
    end
  end

  defp dir_entries(paths) do
    paths
    |> Enum.flat_map(&parents/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{name: &1, type: :directory, mode: 0o755, size: 0, linkname: nil, content: nil})
  end

  defp parents(path) do
    case Path.dirname(path) do
      "." -> []
      dir -> parents(dir) ++ [dir]
    end
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end
end
