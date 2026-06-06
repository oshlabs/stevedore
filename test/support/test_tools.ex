defmodule Stevedore.TestTools do
  @moduledoc """
  Test-only helpers for locating external oracle binaries and skipping cases when a required tool
  isn't installed.

  The integration suites (`:external`, `:conformance`, `:interop`) drive real tools — `skopeo`,
  `crane`, `cosign`, `podman`, `oras`, `regctl`, `go`. A machine without one of them should still
  get a clean run: the missing cases are *skipped*, never failed.

  Two of the tools (`oras`, `regctl`) are typically `go install`ed into `~/go/bin`, which may not
  be on `PATH`. `find/1` falls back to `~/go/bin` so the suite works either way. See
  `docs/TESTING.md`.

  ## Usage

      use ExUnit.Case
      import Stevedore.TestTools

      tool_test "skopeo reads our oci layout", ["skopeo"] do
        assert {_, 0} = System.cmd(find("skopeo"), ["--version"])
      end

  When every listed tool resolves, `tool_test/3` expands to a normal `test`. When any is missing it
  expands to a `test` tagged `@tag skip: "missing tools: …"`, so ExUnit reports it as skipped with
  the reason.
  """

  # `go install` default GOBIN. Resolved at compile time; tools don't appear mid-run.
  @go_bin Path.expand("~/go/bin")

  @doc """
  Absolute path to `tool`, searching `PATH` first, then `~/go/bin`. Returns `nil` if not found.
  """
  @spec find(String.t()) :: String.t() | nil
  def find(tool), do: System.find_executable(tool) || go_bin(tool)

  @doc "Whether `tool` is runnable (on `PATH` or in `~/go/bin`)."
  @spec available?(String.t()) :: boolean()
  def available?(tool), do: find(tool) != nil

  @doc "The subset of `tools` that are not installed."
  @spec missing([String.t()]) :: [String.t()]
  def missing(tools), do: Enum.reject(tools, &available?/1)

  @doc """
  Whether a registry is listening at `url` (an `http(s)://host:port` base).

  A fast TCP connect to the host/port — enough to decide skip-vs-run for the `:external` suite
  without a Distribution probe. Defaults point at localhost (instant `ECONNREFUSED` when the
  `docker-compose.test.yml` registries are down), so this stays cheap and offline.
  """
  @spec registry_up?(String.t()) :: boolean()
  def registry_up?(url) do
    uri = URI.parse(url)

    case :gen_tcp.connect(String.to_charlist(uri.host), uri.port, [active: false], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  @doc """
  Defines a test that needs a reachable registry at `url`.

  Like `tool_test/3`, but the skip condition is registry reachability rather than an installed
  binary — so a machine with no `docker-compose.test.yml` stack up gets a clean, skipped run.
  """
  defmacro registry_test(name, url, do: body) do
    quote do
      if Stevedore.TestTools.registry_up?(unquote(url)) do
        test unquote(name) do
          unquote(body)
        end
      else
        @tag skip: "registry not reachable: #{unquote(url)}"
        test unquote(name) do
          unquote(body)
        end
      end
    end
  end

  @spec go_bin(String.t()) :: String.t() | nil
  defp go_bin(tool) do
    path = Path.join(@go_bin, tool)
    if File.exists?(path), do: path
  end

  @doc """
  Defines a test that depends on external `tools` (a list of binary names).

  Expands to a normal `test` when all tools are present, or to a `@tag skip:`-ped `test` naming the
  missing tool(s) otherwise — so a tool-less machine gets a clean, skipped run instead of a failure.
  """
  defmacro tool_test(name, tools, do: body) do
    quote do
      missing = Stevedore.TestTools.missing(unquote(tools))

      if missing == [] do
        test unquote(name) do
          unquote(body)
        end
      else
        @tag skip: "missing tools: #{Enum.join(missing, ", ")}"
        test unquote(name) do
          unquote(body)
        end
      end
    end
  end
end
