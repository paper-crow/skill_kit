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
      source_url: "https://github.com/paper-crow/skill_kit",
      homepage_url: "https://github.com/paper-crow/skill_kit",
      docs: docs(),
      aliases: aliases()
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.2", only: [:dev, :test]},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      {:mox, "~> 1.2", only: :test},
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp docs do
    [
      main: "SkillKit",
      extras: ["README.md"],
      groups_for_modules: [
        "Public API": [
          SkillKit,
          SkillKit.AgentRef
        ],
        "Agent System": [
          SkillKit.Agent,
          SkillKit.Agent.Definition,
          SkillKit.Agent.Server,
          SkillKit.Agent.Mailbox,
          SkillKit.Agent.Core,
          SkillKit.Agent.Infrastructure,
          SkillKit.Agent.SubagentSupervisor,
          SkillKit.Agent.ToolBuilder
        ],
        "LLM Providers": [
          SkillKit.LLM,
          SkillKit.LLM.Message,
          SkillKit.LLM.Anthropic,
          SkillKit.LLM.Anthropic.Encoder,
          SkillKit.LLM.Anthropic.Decoder,
          SkillKit.LLM.Metadata,
          Anthropic,
          Anthropic.Client
        ],
        "Skills & Kits": [
          SkillKit.Skill,
          SkillKit.Kit,
          SkillKit.Catalog,
          SkillKit.Backend,
          SkillKit.Backend.Filesystem,
          SkillKit.Backend.Filesystem.Parser,
          SkillKit.Frontmatter
        ],
        "Execution & Hooks": [
          SkillKit.Handler,
          SkillKit.Handler.Behaviour,
          SkillKit.Handler.Shell,
          SkillKit.Handler.ToolDefinition,
          SkillKit.Execution,
          SkillKit.Hook
        ],
        Authorization: [
          SkillKit.Authorization,
          SkillKit.AuthorizationProvider,
          SkillKit.Scope
        ],
        Persistence: [
          SkillKit.Conversation.Store,
          SkillKit.Conversation.Store.Filesystem
        ],
        Infrastructure: [
          SkillKit.Supervisor,
          SkillKit.Registry
        ]
      ]
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
      ]
    ]
  end

  defp description do
    "An Elixir framework for building LLM agent systems with skills, tools, and subagent delegation."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/paper-crow/skill_kit"},
      maintainers: ["SkillKit Authors"]
    ]
  end
end
