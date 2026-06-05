defmodule Mix.Tasks.Stevedore.Sync do
  @shortdoc "Bulk-copy images from a spec file"

  @moduledoc """
  Copy many images from a declarative spec file. Each non-blank line is `SRC DST` (lines starting
  with `#` are comments).

      mix stevedore.sync SPEC [--scheme http|https]

  ## Example spec

      docker://alpine:3.20   oci:./mirror/alpine:3.20
      docker://debian:12     oci:./mirror/debian:12
  """

  use Mix.Task

  alias Stevedore.CLI

  @switches [scheme: :string]

  @impl true
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)

    case args do
      [spec] ->
        CLI.start_app()
        jobs = spec |> File.read!() |> parse_jobs()
        {:ok, results} = Stevedore.sync(jobs, Keyword.take(opts, [:scheme]))
        Enum.each(results, &report/1)

      _ ->
        Mix.raise("usage: mix stevedore.sync SPEC")
    end
  end

  defp parse_jobs(contents) do
    for line <- String.split(contents, "\n", trim: true),
        trimmed = String.trim(line),
        trimmed != "" and not String.starts_with?(trimmed, "#"),
        [src, dst] <- [String.split(trimmed, ~r/\s+/, parts: 2)] do
      {src, dst}
    end
  end

  defp report({{src, dst}, {:ok, %{digest: digest}}}),
    do: Mix.shell().info("#{src} -> #{dst}  #{digest}")

  defp report({{src, dst}, {:error, reason}}),
    do: Mix.shell().error("#{src} -> #{dst}  FAILED: #{CLI.format_error(reason)}")
end
