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
      aliases: aliases(),
      consolidate_protocols: Mix.env() != :test
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
      extras: [
        "README.md",
        "guides/examples.md",
        "guides/architecture.md",
        "guides/skill-format.md",
        "guides/llm-providers.md",
        "guides/providers.md",
        "guides/hooks-and-execution.md",
        "guides/authorization.md",
        "guides/telemetry.md",
        "guides/conversations.md"
      ],
      groups_for_extras: [
        Guides: Path.wildcard("guides/*.md")
      ],
      groups_for_modules: [
        "Public API": [
          SkillKit,
          SkillKit.AgentRef
        ],
        "Types & Events": [
          SkillKit.Types.UserMessage,
          SkillKit.Types.AssistantMessage,
          SkillKit.Types.SystemMessage,
          SkillKit.Types.ToolCall,
          SkillKit.Types.ToolResult,
          SkillKit.Event.Delta,
          SkillKit.Event.ToolCallStart,
          SkillKit.Event.ToolCallComplete,
          SkillKit.Event.Usage,
          SkillKit.Event.Done,
          SkillKit.Event.Error,
          SkillKit.Event.Streamable
        ],
        "Agent System": [
          SkillKit.Agent,
          SkillKit.Agent.Server,
          SkillKit.Agent.Mailbox,
          SkillKit.Agent.Core,
          SkillKit.Agent.SubagentSupervisor
        ],
        "LLM Providers": [
          SkillKit.LLM,
          SkillKit.LLM.Anthropic,
          SkillKit.LLM.Anthropic.Encoder
        ],
        "Anthropic Client": [
          Anthropic,
          Anthropic.Client,
          Anthropic.Event,
          Anthropic.Event.MessageStart,
          Anthropic.Event.ContentBlockStart,
          Anthropic.Event.ContentBlockDelta,
          Anthropic.Event.ContentBlockStop,
          Anthropic.Event.MessageDelta,
          Anthropic.Event.MessageStop,
          Anthropic.Telemetry
        ],
        "Skills & Kits": [
          SkillKit.Skill,
          SkillKit.Kit,
          SkillKit.Kit.Memory,
          SkillKit.Catalog,
          SkillKit.Kit.Provider,
          SkillKit.Kit.Local,
          SkillKit.Kit.Local.Parser,
          SkillKit.Frontmatter
        ],
        "Execution & Hooks": [
          SkillKit.Tool.Runner,
          SkillKit.Tool,
          SkillKit.Tools.Shell,
          SkillKit.Tool.Definition,
          SkillKit.Pipeline,
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
        Telemetry: [
          SkillKit.Telemetry
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
