defmodule Mix.Tasks.Stevedore.Delete do
  @shortdoc "Delete a manifest by tag or digest"

  @moduledoc """
  Delete a manifest from a transport.

      mix stevedore.delete REF [--scheme http|https]
  """

  use Mix.Task

  alias Stevedore.CLI

  @switches [scheme: :string]

  @impl true
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)

    case args do
      [ref] ->
        CLI.start_app()
        CLI.unwrap!(Stevedore.delete(ref, Keyword.take(opts, [:scheme])))
        Mix.shell().info("deleted #{ref}")

      _ ->
        Mix.raise("usage: mix stevedore.delete REF")
    end
  end
end
