defmodule Stevedore.ConformanceTest do
  @moduledoc """
  Runs the official **OCI distribution-spec conformance** suite against a live `Stevedore.Server`.

  This is the highest-value single check on `Stevedore.Plug`: a third-party Go/Ginkgo binary,
  written to the spec and free of our own blind spots, exercises the `/v2` API across all four
  workflows — **pull, push, content-discovery (referrers), and content-management (deletion)**. We
  assert the suite reports zero failures by parsing the emitted `junit.xml`.

  Tag: `:conformance` (excluded from the default hermetic `mix test`). Run it with:

      mix test --include conformance

  Needs a Go toolchain to build the binary (cached under `_build/conformance/`; see
  `Stevedore.Conformance`). The module **skips cleanly** when `go` is absent, so a tool-less machine
  still gets a green run.

  Spec & oracle:

    * distribution-spec v1.1.0: <https://github.com/opencontainers/distribution-spec/blob/v1.1.0/spec.md>
    * conformance README (env-var contract):
      <https://github.com/opencontainers/distribution-spec/blob/v1.1.0/conformance/README.md>
  """

  use ExUnit.Case, async: false

  alias Stevedore.Conformance

  @moduletag :conformance
  @moduletag :tmp_dir

  # Skip cleanly (don't fail) on a machine without a Go toolchain — the binary can't be built there.
  if not Stevedore.TestTools.available?("go") do
    @moduletag skip: "conformance: go toolchain not installed"
  end

  setup_all do
    case Conformance.build() do
      {:ok, binary} ->
        {:ok, binary: binary}

      {:error, reason} ->
        # An opted-in run with `go` present but no network/buildable toolchain: surface it loudly
        # rather than pretend the suite passed.
        raise "could not build the conformance binary:\n#{reason}"
    end
  end

  test "distribution-spec conformance suite passes for pull/push/discovery/management",
       %{tmp_dir: dir, binary: binary} do
    port = free_port()

    # No auth challenge, but allow writes — the suite pushes blobs and manifests. Read-only is the
    # plug default, so an explicit allow-all `:authorize` is required for the push/management flows.
    start_supervised!(
      {Stevedore.Server,
       store: Path.join(dir, "registry"), port: port, authorize: fn _, _, _ -> :ok end}
    )

    run_dir = Path.join(dir, "run")
    File.mkdir_p!(run_dir)

    # Env-var contract per the conformance README. All four workflows enabled — pull is mandatory;
    # push/discovery/management are SHOULD-level in the spec but Stevedore implements them, so we
    # hold all four to green. Cross-mount is left automatic-off (the optional from-arg path).
    env = [
      {"OCI_ROOT_URL", "http://localhost:#{port}"},
      {"OCI_NAMESPACE", "stevedore/conformance"},
      {"OCI_CROSSMOUNT_NAMESPACE", "stevedore/crossmount"},
      {"OCI_TEST_PULL", "1"},
      {"OCI_TEST_PUSH", "1"},
      {"OCI_TEST_CONTENT_DISCOVERY", "1"},
      {"OCI_TEST_CONTENT_MANAGEMENT", "1"},
      {"OCI_AUTOMATIC_CROSSMOUNT", "0"}
    ]

    # Run in `run_dir` so the binary drops junit.xml/report.html there. A non-zero exit means the
    # suite failed; we still parse junit.xml to name the offending testcases in the assertion.
    {output, status} = System.cmd(binary, [], cd: run_dir, env: env, stderr_to_stdout: true)
    failures = failing_testcases(Path.join(run_dir, "junit.xml"))

    assert status == 0 and failures == [],
           """
           conformance suite failed (exit #{status}); failing testcases:
           #{failures |> Enum.map(&("  - " <> &1)) |> Enum.join("\n")}

           --- suite output (tail) ---
           #{output |> String.split("\n") |> Enum.take(-40) |> Enum.join("\n")}
           """
  end

  # An ephemeral free port. Tiny TOCTOU window between close and the server's bind, matching the
  # pattern in `Stevedore.ServerTest`; acceptable for a single non-async test.
  @spec free_port() :: :inet.port_number()
  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  # Names of the `<testcase>`s carrying a `<failure>` or `<error>` child, via stdlib :xmerl XPath.
  # The exit code is the ground truth for pass/fail; this only enriches the assertion message.
  # `:xmerl` is a test-only application (see mix.exs `test_applications/1`) — it is on the code path
  # under `:test` but not shipped to consumers of the library.
  @spec failing_testcases(String.t()) :: [String.t()]
  defp failing_testcases(junit_path) do
    if File.exists?(junit_path) do
      {doc, _rest} = junit_path |> String.to_charlist() |> :xmerl_scan.file()

      ~c"//testcase[failure or error]"
      |> :xmerl_xpath.string(doc)
      |> Enum.map(fn testcase ->
        {:xmlObj, :string, name} = :xmerl_xpath.string(~c"string(@name)", testcase)
        to_string(name)
      end)
    else
      ["(no junit.xml produced — the suite likely failed to start)"]
    end
  end
end
