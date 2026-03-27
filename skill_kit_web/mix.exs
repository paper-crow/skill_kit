defmodule SkillKitWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :skill_kit_web,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      deps: deps(),
      name: "SkillKit Web",
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [
      mod: {SkillKitWeb.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:skill_kit, path: ".."},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.0"},
      {:ecto, "~> 3.12"},
      {:ecto_sql, "~> 3.12"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:esbuild, "~> 0.8", only: :dev},
      {:tailwind, "~> 0.2", only: :dev},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ],
      setup: ["deps.get", "assets.setup", "assets.build"],
      dev: "run --no-halt",
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind skill_kit_web", "esbuild skill_kit_web"]
    ]
  end
end
