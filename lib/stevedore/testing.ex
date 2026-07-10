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

  defp dir_entries(paths) do
    paths
    |> Enum.flat_map(&parents/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(
      &%{name: &1, type: :directory, mode: 0o755, size: 0, linkname: nil, content: nil}
    )
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
