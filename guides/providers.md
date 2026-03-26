# Skill Providers

A **provider** is a data source that produces kits — bundles of `%SkillKit.Skill{}`
structs and agent definitions. `SkillKit.Catalog` queries providers on every request
and aggregates their kits in real time.

---

## The Provider Behaviour

Any module that implements `SkillKit.Kit.Provider` is a valid provider:

```elixir
@callback list_kits(config :: keyword()) :: {:ok, [SkillKit.Kit.t()]} | {:error, term()}
@callback get_kit(config :: keyword(), name :: String.t()) ::
            {:ok, SkillKit.Kit.t()} | {:error, :not_found}

@optional_callbacks [load_kits: 1]
```

`list_kits/1` is the primary callback. It receives the config keyword list you supply
when registering the provider and must return `{:ok, kits}` or `{:error, reason}`.

`get_kit/2` fetches a single kit by name. The default implementation calls
`list_kits/1` and searches the result, so you only need to override it for
performance-sensitive cases.

`load_kits/1` is a legacy callback retained for backwards compatibility. New
providers should implement `list_kits/1` instead.

A `%SkillKit.Kit{}` wraps:

- `:name` — a string identifier for the bundle (e.g. `"files"`)
- `:skills` — list of `%SkillKit.Skill{}` structs
- `:agents` — list of agent definitions (optional)
- `:metadata` — arbitrary map

---

## The "Always Fresh" Model

`SkillKit.Catalog` calls `list_kits/1` on every query — there is no internal
cache. This means the catalog always reflects the live state of its providers.
Dynamic sources like `Kit.Memory` work naturally as a result: skills added at
runtime appear immediately on the next request without any cache invalidation.

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
my_kit/                        ← becomes kit "my_kit"
  AGENT.md                     ← root agent (optional)
  skills/
    read/SKILL.md              ← skill "read"
    write/SKILL.md             ← skill "write"
  agents/
    summarize.md               ← sub-agent definition (optional)
```

### Skill file format

Each `SKILL.md` file uses YAML frontmatter followed by the skill body:

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

## Built-in: In-Memory Provider

`SkillKit.Kit.Memory` is an `Agent`-backed provider for testing and dynamic skill
injection. Skills can be added or removed at runtime and are visible to the catalog
on the very next query.

```elixir
{:ok, mem} = SkillKit.Kit.Memory.start_link([])

SkillKit.Kit.Memory.put(mem, %SkillKit.Skill{
  name: "greet:hello",
  description: "Say hello.",
  body: "Say hello to $ARGUMENTS."
})

# Remove a skill by fully-qualified name
SkillKit.Kit.Memory.delete(mem, "greet:hello")
```

Pass the pid (or registered name) as the `:provider` key in the provider config:

```elixir
{SkillKit.Kit.Memory, provider: mem}
```

Skills without a namespace separator are grouped under a bare-name kit. Skills
with a `"namespace:skill"` name are grouped into a kit named by the namespace.

---

## Module-backed Kits

`use SkillKit.Kit` turns an Elixir module into a provider that loads skill files
from a `skills/` directory co-located with the module's source file.

```elixir
defmodule MyApp.FilesKit do
  use SkillKit.Kit

  @impl SkillKit.Tool
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
`SkillKit.Tool` (to execute them). The macro generates default
`definition/0` and `resume/3` implementations; you must supply `execute/1`.

---

## Registering Providers as Sources

Pass a `:providers` list to `SkillKit.Catalog.start_link/1` (or embed it in your
supervision tree via `SkillKit.start_agent/2`). Each entry is a
`{provider_module, config}` tuple:

```elixir
children = [
  {SkillKit.Catalog,
   name: MyApp.Catalog,
   providers: [
     {SkillKit.Kit.Local, dir: "/app/priv/skills"},
     {MyApp.FilesKit, []},
     {MyApp.DatabaseProvider, repo: MyApp.Repo}
   ]}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Provider failures emit a `Logger.warning` but do not prevent the catalog from
starting or serving other providers.

---

## Writing a Custom Provider

Implement `SkillKit.Kit.Provider` and return `%SkillKit.Kit{}` structs:

```elixir
defmodule MyApp.DatabaseProvider do
  @behaviour SkillKit.Kit.Provider

  alias MyApp.Repo
  alias MyApp.SkillRecord
  alias SkillKit.Kit
  alias SkillKit.Skill

  @impl true
  def list_kits(config) do
    repo = Keyword.fetch!(config, :repo)

    skills =
      repo.all(SkillRecord)
      |> Enum.map(&to_skill/1)

    kit = %Kit{name: "db", skills: skills}
    {:ok, [kit]}
  rescue
    exception -> {:error, exception}
  end

  @impl true
  def get_kit(config, name) do
    case list_kits(config) do
      {:ok, kits} -> find_kit(kits, name)
      error -> error
    end
  end

  defp find_kit(kits, name) do
    case Enum.find(kits, &(&1.name == name)) do
      nil -> {:error, :not_found}
      kit -> {:ok, kit}
    end
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

Any error returned from `list_kits/1` (or raised and rescued) is logged and
the provider is skipped without crashing the catalog.
