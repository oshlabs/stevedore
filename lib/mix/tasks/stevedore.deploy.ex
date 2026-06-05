defmodule Mix.Tasks.Stevedore.Deploy do
  @shortdoc "Export an image as a static, read-only registry tree"

  @moduledoc """
  Copy an image into a static registry directory and (optionally) emit a web-server config that
  serves it as a read-only `/v2` registry.

      mix stevedore.deploy SRC OUT [options]

  ## Options

    * `--name repo` — repository name in the tree (derived from a registry source otherwise)
    * `--server nginx|caddy` — also emit a server config
    * `--config FILE` — write the config to FILE (otherwise printed)
    * `--port N` — listen port in the config (default 5000)
    * `--scheme http|https` — registry scheme for the source
  """

  use Mix.Task

  alias Stevedore.{CLI, Deploy}

  @switches [name: :string, server: :string, config: :string, port: :integer, scheme: :string]

  @impl true
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)

    case args do
      [src, out] ->
        CLI.start_app()
        CLI.unwrap!(Deploy.tree(src, out, Keyword.take(opts, [:name, :scheme])))
        Mix.shell().info("wrote registry tree to #{out}")
        maybe_config(out, opts)

      _ ->
        Mix.raise("usage: mix stevedore.deploy SRC OUT [--server nginx|caddy --config FILE]")
    end
  end

  defp maybe_config(out, opts) do
    case opts[:server] do
      nil -> :ok
      "nginx" -> emit(out, opts, Deploy.nginx_config(out, Keyword.take(opts, [:port])))
      "caddy" -> emit(out, opts, Deploy.caddy_config(out, Keyword.take(opts, [:port])))
      other -> Mix.raise("unknown --server #{other} (use nginx or caddy)")
    end
  end

  defp emit(_out, opts, {:ok, config}) do
    case opts[:config] do
      nil ->
        Mix.shell().info(config)

      path ->
        File.write!(path, config)
        Mix.shell().info("wrote #{opts[:server]} config to #{path}")
    end
  end
end
