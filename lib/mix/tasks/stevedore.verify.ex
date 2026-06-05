defmodule Mix.Tasks.Stevedore.Verify do
  @shortdoc "Verify an image's signatures against a public key"

  @moduledoc """
  Verify an image's signatures (fetched via the Referrers API / `.sig` tag) against an ECDSA
  public key (PEM). Exits non-zero if no signature satisfies the policy.

      mix stevedore.verify REF --key path/to/key.pub [--scheme http|https]
  """

  use Mix.Task

  alias Stevedore.{CLI, Verify}
  alias Stevedore.Transport.Parse

  @switches [key: :string, scheme: :string]

  @impl true
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)

    with [ref] <- args, key_path when is_binary(key_path) <- opts[:key] do
      CLI.start_app()
      public = File.read!(key_path)
      {transport, tref} = CLI.unwrap!(Parse.parse(ref, Keyword.take(opts, [:scheme])))
      fetched = CLI.unwrap!(Stevedore.Transport.get_manifest(transport, tref))

      verified =
        CLI.unwrap!(Verify.image(fetched.digest, %{keys: [public]}, transport: transport))

      Mix.shell().info("verified: #{length(verified)} signature(s) accepted")
    else
      _ -> Mix.raise("usage: mix stevedore.verify REF --key KEY.pub")
    end
  end
end
