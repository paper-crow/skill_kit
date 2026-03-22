defmodule SkillKit.Backend do
  @moduledoc """
  Behaviour for loading skills and agent definitions.

  A backend is a data source that returns `%SkillKit.Skill{}` and/or
  `%SkillKit.Agent.Definition{}` structs. SkillKit ships
  `SkillKit.Backend.Filesystem` for loading from disk. Host applications
  implement this behaviour for their own storage (Ecto, APIs, in-memory, etc.).

  `load_skills/1` is required. `load_agents/1` is optional — backends
  that don't provide agent definitions simply don't implement it.

  ## Example

      defmodule MyApp.Backend do
        @behaviour SkillKit.Backend

        @impl true
        def load_skills(config) do
          repo = Keyword.fetch!(config, :repo)
          skills = repo.all(MyApp.SkillRecord) |> Enum.map(&to_skill/1)
          {:ok, skills}
        end

        @impl true
        def load_agents(config) do
          repo = Keyword.fetch!(config, :repo)
          agents = repo.all(MyApp.AgentRecord) |> Enum.map(&to_definition/1)
          {:ok, agents}
        end
      end

  ## Configuration

  Backends are always configured as `{module, keyword()}` tuples:

      backends: [
        {SkillKit.Backend.Filesystem, dirs: ["/path/to/skills"]},
        {MyApp.Backend, repo: MyApp.Repo}
      ]

  Bare module atoms are not supported — every backend gets an explicit
  config even if empty: `{MyBackend, []}`.
  """

  @callback load_skills(config :: keyword()) :: {:ok, [SkillKit.Skill.t()]} | {:error, term()}
  @callback load_agents(config :: keyword()) ::
              {:ok, [SkillKit.Agent.Definition.t()]} | {:error, term()}

  @optional_callbacks [load_agents: 1]
end
