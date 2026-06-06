defmodule Stevedore.Conformance do
  @moduledoc """
  Builds and caches the official OCI **distribution-spec conformance** test binary used by
  `Stevedore.ConformanceTest` (the `:conformance` suite).

  The suite is a Go/Ginkgo program: you compile it once into a `conformance.test` binary, then point
  it at a running registry through `OCI_*` environment variables. This module clones the pinned
  distribution-spec tag and runs `go test -c`, caching both under `_build/conformance/` (git-ignored
  via `/_build/`). First build needs network + a Go toolchain (~4s); subsequent runs reuse the cached
  binary.

  Pinned to **`v1.1.0`** (SHA `0f98d91a0afe7ed3ab0f29349beed2bb4ba1507d`) — the OCI 1.1 release
  Stevedore targets, so the `subject`/referrers content-discovery workflow is exercised. Re-pin by
  bumping `@tag` and recording the new SHA here.

    * Repo: <https://github.com/opencontainers/distribution-spec/tree/v1.1.0/conformance>
    * README: <https://github.com/opencontainers/distribution-spec/blob/v1.1.0/conformance/README.md>
  """

  @repo "https://github.com/opencontainers/distribution-spec"
  @tag "v1.1.0"

  @doc "Absolute path to the (possibly not-yet-built) `conformance.test` binary."
  @spec binary() :: String.t()
  def binary, do: Path.join(dir(), "conformance.test")

  @doc """
  Ensures the `conformance.test` binary exists, building it (clone + `go test -c`) if absent.

  Returns `{:ok, path}` or `{:error, reason}` (network/toolchain failure) — the caller decides
  whether to skip or surface. A cached binary short-circuits the clone/build.
  """
  @spec build() :: {:ok, String.t()} | {:error, String.t()}
  def build do
    bin = binary()

    if File.regular?(bin) do
      {:ok, bin}
    else
      with :ok <- ensure_clone(), :ok <- compile(bin), do: {:ok, bin}
    end
  end

  @spec ensure_clone() :: :ok | {:error, String.t()}
  defp ensure_clone do
    if File.dir?(Path.join(repo_dir(), "conformance")) do
      :ok
    else
      File.mkdir_p!(dir())
      File.rm_rf!(repo_dir())

      case System.cmd(
             "git",
             ["clone", "--depth", "1", "--branch", @tag, @repo, repo_dir()],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {out, code} -> {:error, "git clone #{@tag} failed (exit #{code}):\n#{out}"}
      end
    end
  end

  @spec compile(String.t()) :: :ok | {:error, String.t()}
  defp compile(bin) do
    conformance = Path.join(repo_dir(), "conformance")

    case System.cmd("go", ["test", "-c", "-o", bin], cd: conformance, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, "go test -c failed (exit #{code}):\n#{out}"}
    end
  end

  @spec dir() :: String.t()
  defp dir, do: Path.expand("_build/conformance")

  @spec repo_dir() :: String.t()
  defp repo_dir, do: Path.join(dir(), "distribution-spec")
end
