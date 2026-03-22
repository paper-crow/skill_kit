defmodule SkillKit.Backend do
  @moduledoc """
  Behaviour for skill loading backends.

  A backend is a data source that returns `%SkillKit.Skill{}` structs.
  SkillKit ships `SkillKit.Backend.Filesystem` for loading from `.skill.md`
  files on disk. Host applications implement this behaviour for their own
  storage (Ecto, APIs, in-memory, etc.).

  ## Example

      defmodule MyApp.SkillBackend do
        @behaviour SkillKit.Backend

        @impl true
        def load_skills(config) do
          repo = Keyword.fetch!(config, :repo)
          skills = repo.all(MyApp.SkillRecord) |> Enum.map(&to_skill/1)
          {:ok, skills}
        end
      end

  ## Configuration

  Backends are always configured as `{module, keyword()}` tuples:

      backends: [
        {SkillKit.Backend.Filesystem, dirs: ["/path/to/skills"]},
        {MyApp.SkillBackend, repo: MyApp.Repo}
      ]

  Bare module atoms are not supported — every backend gets an explicit
  config even if empty: `{MyBackend, []}`.
  """

  @callback load_skills(config :: keyword()) :: {:ok, [SkillKit.Skill.t()]} | {:error, term()}
end
