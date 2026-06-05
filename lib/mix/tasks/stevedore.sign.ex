defmodule Mix.Tasks.Stevedore.Sign do
  @shortdoc "Sign an image and attach the signature as a referrer"

  @moduledoc """
  Sign an image with an ECDSA private key (PEM) and attach the cosign-compatible signature to it
  via the Referrers API.

      mix stevedore.sign REF --key path/to/key.pem [--scheme http|https]
  """

  use Mix.Task

  alias Stevedore.{CLI, Referrers, Sign}
  alias Stevedore.Transport.Parse

  @switches [key: :string, scheme: :string]

  @impl true
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: @switches)

    with [ref] <- args, key_path when is_binary(key_path) <- opts[:key] do
      CLI.start_app()
      key = %{private: File.read!(key_path)}
      {transport, tref} = CLI.unwrap!(Parse.parse(ref, Keyword.take(opts, [:scheme])))
      fetched = CLI.unwrap!(Stevedore.Transport.get_manifest(transport, tref))

      signature =
        CLI.unwrap!(Sign.sigstore(fetched.digest, key, subject_size: byte_size(fetched.raw)))

      digest = CLI.unwrap!(Referrers.attach(transport, fetched.digest, signature))
      Mix.shell().info("attached signature #{digest}")
    else
      _ -> Mix.raise("usage: mix stevedore.sign REF --key KEY.pem")
    end
  end
end
