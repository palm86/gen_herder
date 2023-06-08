defmodule GenHerder.MixProject do
  use Mix.Project

  def project do
    [
      app: :gen_herder,
      version: "0.1.3",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      source_url: "https://github.com/palm86/gen_herder"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp package() do
    [
      description: "A behaviour for avoiding the stampeding-herd problem.",
      # These are the default files included in the package
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*),
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/palm86/gen_herder"}
    ]
  end

  defp docs() do
    [
      extra_section: false,
      main: "GenHerder"
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.28.5", only: :dev},
      {:credo, "~> 1.6", only: :dev},
      {:dialyxir, "~> 1.3", only: :dev}
    ]
  end

  defp aliases do
    [
      test: ["test --warnings-as-errors"],
      compile: ["compile --warnings-as-errors --all-warnings"]
    ]
  end
end
