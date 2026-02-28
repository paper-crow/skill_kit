defmodule SkillKit do
  @moduledoc """
  SkillKit — programmatic, scope-based authorization for skills.

  SkillKit determines what skills and commands an agent, user, or runtime
  context can access. It provides a registry for discovering available skills
  and an authorization layer for controlling access to them.

  ## Architecture

  SkillKit is built in four phases:

  1. **Registry Foundation** (Phase 1) — This phase. A GenServer+ETS-backed
     skill registry that host applications supervise via `child_spec/1`.

  2. **Skill Loader** (Phase 2) — Loads skill definitions from YAML files on
     disk, including behaviour-based validation and hot-reload support.

  3. **Authorization Layer** (Phase 3) — Scope-based access control: grants,
     denials, wildcard matching, and context-based authorization decisions.

  4. **Adapters** (Phase 4) — Integrations with AI provider APIs (Anthropic,
     OpenAI) that filter tool lists based on authorization decisions.

  ## Quick Start

  Add `SkillKit.Supervisor` to your application's supervision tree:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            {SkillKit.Supervisor, []}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Usage

      skill = %SkillKit.Skill{name: "files:read", namespace: "files"}
      :ok = SkillKit.Registry.register(skill)
      {:ok, skill} = SkillKit.Registry.get_skill("files:read")

  ## Configuration

  All configuration is passed via `start_link/1` opts — SkillKit never calls
  `Application.get_env/2`. This makes it safe to use in libraries and umbrella
  apps without polluting the application configuration namespace.
  """
end
