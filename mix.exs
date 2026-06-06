defmodule Stevedore.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/oshlabs/stevedore"

  def project do
    [
      app: :stevedore,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      name: "Stevedore",
      source_url: @source_url,
      description:
        "A library-first, daemonless OCI toolkit for Elixir — everything you can do to a container image except run it.",
      package: package(),
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:public_key, :crypto, :mix],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ]
    ]
  end

  # Weightless by default: no `mod:`, so adding Stevedore starts no processes.
  # The standalone registry server boots only via an explicit Stevedore.start_link/1.
  def application do
    [
      # :xmerl is test-only (the :conformance suite parses junit.xml). Deps compile under :prod, so
      # consumers of the library never carry it — keeping the runtime weightless.
      extra_applications: [:logger, :crypto, :public_key] ++ test_applications(Mix.env())
    ]
  end

  defp test_applications(:test), do: [:xmerl]
  defp test_applications(_), do: []

  # Test-only support modules (oracle-tool helpers, fixtures) compile only under :test.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Optional: only loaded when you use a mode that needs it (see PLAN §5).
      {:req, "~> 0.5", optional: true},
      {:plug, "~> 1.16", optional: true},
      {:bandit, "~> 1.5", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      # Test-only: validate emitted JSON against the vendored OCI image-spec schemas (Step 9B).
      # Kept out of the runtime to preserve the "weightless by default" invariant (AGENTS.md).
      {:ex_json_schema, "~> 0.10", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE docs .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/EXAMPLES.md",
        "docs/REFERENCES.md",
        "docs/TESTING.md",
        "AGENTS.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ["docs/EXAMPLES.md", "docs/REFERENCES.md", "docs/TESTING.md", "AGENTS.md"]
      ]
    ]
  end
end
