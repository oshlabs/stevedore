defmodule Mix.Tasks.Stevedore.Copy do
  @shortdoc "Copy an image between transports, preserving digests"

  @moduledoc """
  Copy an image from one transport to another.

      mix stevedore.copy SRC DST [options]

  SRC and DST are transport-prefixed references (`docker://`, `oci:`, `oci-archive:`,
  `docker-archive:`, `dir:`, `static:`).

  ## Options

    * `--all` — copy a whole multi-arch index
    * `--platform os/arch` — select one platform from an index
    * `--format oci|docker` — convert the manifest format
    * `--scheme http|https` — registry scheme (default https)

  ## Examples

      mix stevedore.copy docker://alpine:3.20 oci:./alpine:3.20
      mix stevedore.copy docker://alpine:3.20 docker://ghcr.io/me/alpine:3.20 --all
  """

  use Mix.Task

  alias Stevedore.CLI

  @switches [all: :boolean, platform: :string, format: :string, scheme: :string]

  @impl true
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)

    case args do
      [src, dst] ->
        CLI.start_app()
        %{digest: digest} = CLI.unwrap!(Stevedore.copy(src, dst, copy_opts(opts)))
        Mix.shell().info(to_string(digest))

      _ ->
        Mix.raise(
          "usage: mix stevedore.copy SRC DST [--all --platform os/arch --format oci|docker]"
        )
    end
  end

  defp copy_opts(opts) do
    opts
    |> Keyword.take([:all, :platform, :scheme])
    |> maybe_format(opts[:format])
  end

  defp maybe_format(opts, nil), do: opts
  defp maybe_format(opts, "oci"), do: Keyword.put(opts, :format, :oci)
  defp maybe_format(opts, "docker"), do: Keyword.put(opts, :format, :docker)
  defp maybe_format(_opts, other), do: Mix.raise("unknown --format #{other} (use oci or docker)")
end
