# Skill Providers

A **provider** is a data source that produces kits — bundles of `%SkillKit.Skill{}`
structs and agent definitions. SkillKit loads providers at boot time and registers
all skills they return into the registry.

---

## The Provider Behaviour

Any module that implements `SkillKit.Kit.Provider` is a valid provider:

```elixir
@callback load_kits(config :: keyword()) :: {:ok, [SkillKit.Kit.t()]} | {:error, term()}
```

`load_kits/1` receives the config keyword list you supply when registering the
provider as a source. It must return `{:ok, kits}` where each kit is a
`%SkillKit.Kit{}`, or `{:error, reason}` on failure.

A `%SkillKit.Kit{}` wraps:

- `:name` — a string identifier for the bundle (e.g. `"files"`)
- `:skills` — list of `%SkillKit.Skill{}` structs
- `:agents` — list of agent definitions (optional)
- `:metadata` — arbitrary map

---

## Built-in: Filesystem Provider

`SkillKit.Kit.Local` loads kits from directories on disk. Each directory
becomes one kit; the kit name is the directory's basename.

**Config key:** `:dir` — an absolute directory path.

```elixir
{SkillKit.Kit.Local, dir: "/app/skills/files"}
```

### Directory structure

```
skills/
  files/                     ← becomes kit "files"
    read.skill.md
    write.skill.md
    summarize/
      AGENT.md               ← agent definition (optional)
  tools/                     ← becomes kit "tools"
    web_search.skill.md
```

### Skill file format

Each `*.skill.md` file uses YAML frontmatter followed by the skill body:

```markdown
---
name: read
description: Read the contents of a file at the given path.
---
Read the file at $ARGUMENTS and return its full contents.
```

Required frontmatter fields: `name`, `description`. The skill is registered
under the fully-qualified name `"<kit_name>:<skill_name>"` (e.g. `"files:read"`).

Parse failures are logged as warnings and skipped; the rest of the kit still loads.

---

## Module-backed Kits

`use SkillKit.Kit` turns an Elixir module into a provider that loads skill files
from a `skills/` directory co-located with the module's source file.

```elixir
defmodule MyApp.FilesKit do
  use SkillKit.Kit

  @impl SkillKit.Handler.Behaviour
  def execute(%SkillKit.Pipeline{} = execution) do
    # handle skill execution
  end
end
```

The kit name is inferred from the last module segment, downcased and underscored
(`FilesKit` → `"files_kit"`). Override either option:

```elixir
use SkillKit.Kit, name: "files", skills_dir: "/abs/path/to/skills"
```

`use SkillKit.Kit` implements both `SkillKit.Kit.Provider` (to load skills) and
`SkillKit.Handler.Behaviour` (to execute them). The macro generates default
`tool_definition/0` and `resume/3` implementations; you must supply `execute/1`.

---

## Registering Providers as Sources

Pass a `:sources` list to `SkillKit.Registry.start_link/1` (or embed it in your
supervision tree). Each entry is a `{provider_module, config}` tuple:

```elixir
children = [
  {SkillKit.Registry,
   name: MyApp.SkillRegistry,
   sources: [
     {SkillKit.Kit.Local, dir: "/app/priv/skills"},
     {MyApp.FilesKit, []},
     {MyApp.DatabaseProvider, repo: MyApp.Repo}
   ]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Sources are loaded in order. **First-registered-wins**: if two providers provide
a skill with the same name, the earlier source's version is kept. Provider
failures emit a `Logger.warning` but do not prevent the registry from starting.

---

## Writing a Custom Provider

Implement `SkillKit.Kit.Provider` and return `%SkillKit.Kit{}` structs:

```elixir
defmodule MyApp.DatabaseProvider do
  @behaviour SkillKit.Kit.Provider

  alias MyApp.Repo
  alias MyApp.SkillRecord
  alias SkillKit.{Kit, Skill}

  @impl true
  def load_kits(config) do
    repo = Keyword.fetch!(config, :repo)

    skills =
      repo.all(SkillRecord)
      |> Enum.map(&to_skill/1)

    kit = %Kit{name: "db", skills: skills}
    {:ok, [kit]}
  rescue
    exception -> {:error, exception}
  end

  defp to_skill(%SkillRecord{} = record) do
    %Skill{
      name: "db:#{record.slug}",
      namespace: "db",
      description: record.description,
      body: record.body,
      handler: MyApp.DatabaseHandler
    }
  end
end
```

Then register it as a source:

```elixir
{MyApp.DatabaseProvider, repo: MyApp.Repo}
```

Any error returned from `load_kits/1` (or raised and rescued) is logged and
the provider is skipped without crashing the registry.
