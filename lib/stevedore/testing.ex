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
  bundled `deckhand` binary (statically linked, libc-free, ~19 KB; source,
  pinned-Zig `build.sh`, and CI byte-diff guard in `priv/deckhand/`) layered
  at `/bin/deckhand`, plus the `etc/stevedore-test` marker file.

  deckhand is a container diagnostic: an event-printing REPL (console
  resizes, signals, HTTP hits — and it runs until signaled, so it doubles as
  the keepalive process) plus a GET-only web server on 0.0.0.0/:: (default
  port 8080) whose URL space mirrors the command set — `/env`, `/id`,
  `/hostname`, `/uname`, `/ifaces`, `/mounts`, `/cat/PATH`, `/ls/PATH`,
  `/find/PATH`, `/ping/H`,
  `/resolve/N` — so tests can inspect the container's view of its world from
  outside. See `priv/deckhand/README.md`.

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
      entries =
        dir_entries([marker, bin_path]) ++
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
