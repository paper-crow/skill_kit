# Backend Architecture Design

## Problem

The Registry currently couples skill loading to the filesystem. Skills are loaded from directories via `skill_dirs` at boot time using the `Loader` module. This works for `.skill.md` files on disk but prevents loading skills from other sources — databases, APIs, programmatic registration, or custom formats.

The `Loader` module is a top-level public module, but its only purpose is parsing `.skill.md` files — a filesystem concern that should not be part of the public API.

## Design

### Backend Behaviour

A simple contract for skill sources:

```elixir
defmodule SkillKit.Backend do
  @callback load_skills(config :: keyword()) :: {:ok, [SkillKit.Skill.t()]} | {:error, term()}
end
```

Single callback. Takes backend-specific config (keyword list), returns a list of `%Skill{}` structs. No process management, no side effects. Backends are pure data sources.

SkillKit ships one backend: `SkillKit.Backend.Filesystem`. Host applications implement the behaviour for their own storage (Ecto, APIs, in-memory, etc.).

### SkillKit.Backend.Filesystem

The one backend SkillKit ships. Scans directories for `.skill.md` files and parses them into `%Skill{}` structs.

```elixir
defmodule SkillKit.Backend.Filesystem do
  @behaviour SkillKit.Backend

  @impl true
  def load_skills(config) do
    dirs = Keyword.fetch!(config, :dirs)

    skills =
      dirs
      |> Enum.flat_map(&discover_skill_files/1)
      |> Enum.reduce({[], []}, &load_skill_file/2)
      |> handle_results()
  end
end
```

**Config options:**
- `:dirs` (required) — list of directory paths to scan recursively for `**/*.skill.md` files

Malformed files are skipped with a warning, same as the current Registry behavior. The backend returns successfully loaded skills — partial success is not an error.

### SkillKit.Backend.Filesystem.Parser

The current `SkillKit.Loader` module moves and is renamed to `SkillKit.Backend.Filesystem.Parser`. Same code, same YAML frontmatter parsing, same `.skill.md` format support. No longer part of the public API — it is an internal detail of the Filesystem backend.

Consumers never call the Loader directly. The Filesystem backend is the entry point for loading skills from disk.

### Registry Changes

The Registry drops `skill_dirs` and gains `backends`:

```elixir
# Configuration
SkillKit.Registry.start_link(
  name: MyApp.Registry,
  backends: [
    {SkillKit.Backend.Filesystem, dirs: ["/path/to/skills"]},
    {MyApp.EctoSkillBackend, repo: MyApp.Repo}
  ]
)
```

**Backend config format:** Always a `{module, keyword()}` tuple. Bare module atoms are not supported — every backend gets an explicit config even if empty: `{MyBackend, []}`.

**Boot-time loading (`handle_continue`):**

1. Iterate configured backends in order
2. Call `load_skills/1` on each backend with its config
3. Insert returned skills into ETS
4. First-registered-wins for name conflicts — if two backends return a skill with the same name, the backend listed first takes precedence
5. Log a warning for any backend that returns `{:error, reason}`

```elixir
@impl true
def handle_continue(:load_skills, state) do
  backends = Keyword.get(state.opts, :backends, [])

  Enum.each(backends, fn {backend_mod, backend_config} ->
    case backend_mod.load_skills(backend_config) do
      {:ok, skills} ->
        Enum.each(skills, fn skill ->
          # First-registered-wins: only insert if not already present
          if :ets.lookup(state.table, skill.name) == [] do
            :ets.insert(state.table, {skill.name, skill})
          end
        end)

      {:error, reason} ->
        Logger.warning("SkillKit: backend #{inspect(backend_mod)} failed: #{inspect(reason)}")
    end
  end)

  {:noreply, state}
end
```

**What stays the same:**
- GenServer+ETS hybrid pattern
- Public API: `register/2`, `unregister/2`, `get_skill/2`, `list_skills/2`
- ETS table design: `:set`, `:protected`, `read_concurrency: true`
- Runtime registration via `register/2` — unchanged, independent of backends
- Namespace validation on register

**What's removed:**
- `skill_dirs` option
- `load_from_dirs/1`, `discover_skill_files/1`, `load_skill_file/3` private functions (moved to Filesystem backend)

### Supervisor Changes

The Supervisor passes `backends` instead of `skill_dirs`:

```elixir
# Configuration
SkillKit.Supervisor.start_link(
  backends: [
    {SkillKit.Backend.Filesystem, dirs: ["priv/skills"]}
  ]
)
```

**What's removed:**
- `:skill_dirs` option (no backwards compatibility shim — clean break)

### Host Application Backend Example

Host applications implement `SkillKit.Backend` for their own storage:

```elixir
defmodule MyApp.EctoSkillBackend do
  @behaviour SkillKit.Backend

  @impl true
  def load_skills(config) do
    repo = Keyword.fetch!(config, :repo)

    skills =
      repo.all(MyApp.SkillRecord)
      |> Enum.map(fn record ->
        %SkillKit.Skill{
          name: record.name,
          namespace: record.namespace,
          description: record.description,
          body: record.body,
          required_scope: record.required_scope || [],
          location: nil
        }
      end)

    {:ok, skills}
  end
end
```

SkillKit does not ship Ecto backends, schemas, or migrations. The host application owns its storage layer entirely.

## Impact on Existing Code

| Module | Change |
|--------|--------|
| `SkillKit.Backend` | **New** — behaviour with `load_skills/1` callback |
| `SkillKit.Backend.Filesystem` | **New** — extracts filesystem loading from Registry |
| `SkillKit.Backend.Filesystem.Parser` | **Moved and renamed** from `SkillKit.Loader` — parses `.skill.md` content, no longer public |
| `SkillKit.Registry` | **Modified** — `skill_dirs` → `backends`, boot loading delegates to backends |
| `SkillKit.Supervisor` | **Modified** — `skill_dirs` → `backends` passthrough |
| `SkillKit.Catalog` | **Unchanged** |
| `SkillKit.ToolExecution` | **Unchanged** |
| `SkillKit.Execution` | **Unchanged** |
| Tests | **Modified** — update to use `backends:` config, test fixtures use Filesystem backend |
