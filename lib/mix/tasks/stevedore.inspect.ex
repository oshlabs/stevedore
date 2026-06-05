defmodule Mix.Tasks.Stevedore.Inspect do
  @shortdoc "Show a manifest without pulling layers"

  @moduledoc """
  Inspect the manifest of an image at any transport.

      mix stevedore.inspect REF [options]

  ## Options

    * `--raw` — print the raw manifest bytes
    * `--scheme http|https` — registry scheme (default https)
  """

  use Mix.Task

  alias Stevedore.{CLI, Manifest}
  alias Stevedore.Transport.Parse

  @switches [raw: :boolean, scheme: :string]

  @impl true
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)

    case args do
      [ref] ->
        CLI.start_app()
        {transport, tref} = CLI.unwrap!(Parse.parse(ref, Keyword.take(opts, [:scheme])))
        fetched = CLI.unwrap!(Stevedore.Transport.get_manifest(transport, tref))
        render(fetched, opts[:raw])

      _ ->
        Mix.raise("usage: mix stevedore.inspect REF [--raw]")
    end
  end

  defp render(fetched, true), do: Mix.shell().info(fetched.raw)

  defp render(fetched, _) do
    Mix.shell().info("Media-Type:  #{fetched.media_type}")
    Mix.shell().info("Digest:      #{fetched.digest}")
    summarize(Manifest.parse(fetched.raw, fetched.media_type))
  end

  defp summarize({:ok, manifest}) do
    case Manifest.kind(manifest) do
      :index ->
        {:ok, entries} = Manifest.manifests(manifest)
        Mix.shell().info("Platforms:   #{length(entries)}")

      :manifest ->
        {:ok, layers} = Manifest.layers(manifest)
        Mix.shell().info("Layers:      #{length(layers)}")
    end
  end

  defp summarize(_), do: :ok
end
