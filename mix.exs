defmodule SkillKit.MixProject do
  use Mix.Project

  def project do
    [
      app: :skill_kit,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      name: "SkillKit",
      source_url: "https://github.com/example/skill_kit",
      homepage_url: "https://github.com/example/skill_kit",
      docs: [
        main: "SkillKit",
        extras: ["README.md"]
      ]
    ]
  end

  # Compile test/support helpers in the test environment so shared test modules
  # (e.g., SkillKit.TestSkills.Echo) are available across all test files and
  # are compiled as proper .beam files (enabling Code.ensure_loaded/1 checks).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  # SkillKit is a library — application/0 has no :mod key.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:yaml_elixir, "~> 2.12"},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Programmatic, scope-based authorization for determining what skills and commands an agent, user, or runtime context can access."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/example/skill_kit"},
      maintainers: ["SkillKit Authors"]
    ]
  end
end
