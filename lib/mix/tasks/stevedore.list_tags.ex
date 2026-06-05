defmodule Mix.Tasks.Stevedore.ListTags do
  @shortdoc "List the tags in a repository"

  @moduledoc """
  List the tags held by a transport.

      mix stevedore.list_tags REF [--scheme http|https]
  """

  use Mix.Task

  alias Stevedore.CLI
  alias Stevedore.Transport.Parse

  @switches [scheme: :string]

  @impl true
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)

    case args do
      [ref] ->
        CLI.start_app()
        {transport, _ref} = CLI.unwrap!(Parse.parse(ref, Keyword.take(opts, [:scheme])))
        tags = CLI.unwrap!(Stevedore.Transport.list_tags(transport))
        Enum.each(tags, fn tag -> Mix.shell().info(tag) end)

      _ ->
        Mix.raise("usage: mix stevedore.list_tags REF")
    end
  end
end
