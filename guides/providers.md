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

## Built-in: GitHub Provider

`SkillKit.Kit.GitHub` imports skills from GitHub repositories at runtime. Repos
are downloaded as tarballs, cached locally, and loaded via `Kit.Local`. The
provider ships built-in skills so agents can import repos mid-conversation.

```elixir
{SkillKit.Kit.GitHub,
  allowed_sources: ["paper-crow/*", "community/tools"],
  api_token: {:env, "GITHUB_TOKEN"},
  cache_dir: "/tmp/skill_kit/github"
}
```

See the `SkillKit.Kit.GitHub` moduledoc for reference format, allowed sources
patterns, cache behaviour, and built-in skill details.

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

`use SkillKit.Kit` turns an Elixir module into a provider that reads and parses
all `SKILL.md` and `AGENT.md` files **at compile time** — no runtime filesystem
access is needed. The module implements both `SkillKit.Kit.Provider` (to supply
skills) and `SkillKit.Tool` (to execute them).

```elixir
defmodule MyApp.FilesKit do
  use SkillKit.Kit

  @impl SkillKit.Tool
  def execute(%SkillKit.ToolExecution{} = execution) do
    # handle skill execution
  end
end
```

### Directory layout

The kit root is the directory containing the module's source file by default.
Skills live in a `skills/` subdirectory; an optional `AGENT.md` at the root
defines the kit's agent identity:

```
lib/my_app/files_kit/
  files_kit.ex               ← defmodule MyApp.FilesKit
  AGENT.md                   ← root agent definition (optional)
  skills/
    read/SKILL.md
    write/SKILL.md
```

### Options

| Option   | Default                          | Description |
|----------|----------------------------------|-------------|
| `:path`  | directory of the source file     | Absolute path to the kit root. Skills are loaded from `<path>/skills/` and AGENT.md from `<path>/AGENT.md`. |
| `:name`  | last module segment, underscored | Override the inferred kit name. |

```elixir
use SkillKit.Kit, name: "files", path: "/abs/path/to/kit"
```

### Compile-time loading

All `SKILL.md` and `AGENT.md` files are read and parsed during compilation.
Parsed structs are stored as module attributes and served from memory at
runtime. Each file is registered as an `@external_resource`, so the module
recompiles automatically when any skill or agent file changes during
development.

### `agent_definition/0`

Kit modules expose an `agent_definition/0` function that returns the parsed
`%SkillKit.Agent{}` from the kit's `AGENT.md`, or `nil` if no
agent file exists. This is useful for passing a kit's agent definition
directly to `SkillKit.start_agent/2`:

```elixir
definition = MyApp.FilesKit.agent_definition()
{:ok, agent} = SkillKit.start_agent(definition, caller: self())
```

### Generated callbacks

The macro generates default implementations for `definition/0`, `resume/3`,
`load_kits/1`, `list_kits/1`, `get_kit/2`, and `agent_definition/0`. All are
overridable. You must supply `execute/1`.

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
