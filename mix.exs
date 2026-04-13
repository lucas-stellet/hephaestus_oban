defmodule HephaestusOban.MixProject do
  use Mix.Project

  @version "0.5.0"
  @source_url "https://github.com/lucas-stellet/hephaestus_oban"

  def project do
    [
      app: :hephaestus_oban,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {HephaestusOban.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:hephaestus, "~> 0.3.0"},
      {:hephaestus_ecto, "~> 0.3.0"},
      {:oban, "~> 2.14"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Oban-based runner adapter for the Hephaestus workflow engine. " <>
      "Durable jobs with retry/backoff, advisory lock serialization, " <>
      "and zero-contention parallel step execution via an auxiliary step_results table."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
