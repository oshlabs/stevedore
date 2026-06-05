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
      deps: deps(),
      name: "Stevedore",
      source_url: @source_url,
      description:
        "A library-first, daemonless OCI toolkit for Elixir — everything you can do to a container image except run it.",
      docs: docs(),
      dialyzer: [
        plt_add_apps: [:public_key, :crypto],
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts"
      ]
    ]
  end

  # Weightless by default: no `mod:`, so adding Stevedore starts no processes.
  # The standalone registry server boots only via an explicit Stevedore.start_link/1.
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key]
    ]
  end

  defp deps do
    [
      # Optional: only loaded when you use a mode that needs it (see PLAN §5).
      {:req, "~> 0.5", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "docs/EXAMPLES.md", "docs/REFERENCES.md"],
      groups_for_extras: [Guides: ["docs/EXAMPLES.md", "docs/REFERENCES.md"]]
    ]
  end
end
