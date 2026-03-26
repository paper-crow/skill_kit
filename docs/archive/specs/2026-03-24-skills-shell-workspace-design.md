# Skills Rename, Shell Registration, Workspace Removal — Design Spec

## Purpose

Three related changes that align SkillKit's naming with its mental model and remove filesystem concepts from the library core:

1. Rename `sources:` to `skills:` — everything providing capabilities is a skill
2. Rename `SkillKit.Tools.Shell` to `SkillKit.Tools.Shell` — registered through `skills:` like everything else
3. Remove `workspace` from `Definition` — the library has no filesystem concept; the Shell handler owns cwd

## Principle

The library core should have no concept of files or filesystem paths. Filesystem awareness belongs to backends (`Backend.Filesystem`) and handlers (`SkillKit.Tools.Shell`) — both registered through the uniform `skills:` interface.

## Design

### 1. `sources:` → `skills:`

Rename the option key on `start_agent`, `start_subagent`, and anywhere else `:sources` appears in the public API. Internal references (Agent.init, Infrastructure, Supervisor, Registry) also update.

```elixir
# Before
SkillKit.start_agent(definition, sources: [{Backend.Filesystem, dirs: ["skills"]}])

# After
SkillKit.start_agent(skills: [{Backend.Filesystem, dir: ".skills"}, {SkillKit.Tools.Shell, cwd: "."}])
```

### 2. `SkillKit.Tools.Shell` → `SkillKit.Tools.Shell`

`SkillKit.Tools.Shell` implements both `Backend` and `Tool` (same pattern as `use SkillKit.Kit`):

- **As a Backend:** `load_kits/1` returns a Kit containing the bash tool definition. No skills, no agents — just the handler registration.
- **As a Handler:** `execute/1` runs shell commands via Port, using the `cwd` from its own config.

Config:
- `cwd:` — working directory for commands. Defaults to `File.cwd!()` if not provided.
- `env:` — environment variables (existing feature, now configured at registration rather than through context).

```elixir
# Registration
{SkillKit.Tools.Shell, cwd: File.cwd!(), env: [{"API_KEY", "..."}]}

# What load_kits returns
%Kit{
  name: "shell",
  skills: [],
  agents: [],
  root_agent: nil,
  metadata: %{tool: SkillKit.Tools.Shell, cwd: cwd, env: env}
}
```

The Shell handler is no longer a default — agents only have bash if `SkillKit.Tools.Shell` is in their `skills:` list. This makes capabilities explicit.

### 3. Remove `workspace` from Definition

- Remove `:workspace` from `Definition` struct, `@enforce_keys`, and `@type t`
- Remove `metadata.workspace` parsing from `Definition.parse/1`
- Remove `context.cwd` from server.ex context map — the server doesn't build cwd for handlers
- The Shell handler reads cwd from its own state, not from the pipeline context

`server.ex` context becomes:
```elixir
# Before
context = %{cwd: state.definition.workspace, scope: state.scope}

# After
context = %{scope: state.scope}
```

The Shell handler gets cwd from the kit metadata that was set during `load_kits`. The mechanism for passing handler config from the kit to the handler at execution time needs to be worked out — currently the pipeline context is how handlers receive runtime info. Options:

**A)** The Shell handler stores its config (cwd, env) in the Kit metadata. When the server builds a pipeline for a shell command, it looks up the Shell handler's kit and passes config through the pipeline context. The server doesn't interpret the config — it just passes it through.

**B)** The Shell handler registers its config in the skill registry at boot. When executing, it reads its own config from the registry. No pipeline context needed for handler config.

**C)** The handler module holds config as module state (set during `load_kits`). Since `load_kits` is called per-agent, the config is per-agent. But modules are global — this doesn't work for multiple agents with different cwd.

**Recommended: (A)** — Kit metadata carries handler config. The server passes it through to the handler in the pipeline context without interpreting it. This is the same pattern already used for module-backed kits where `source_config` is passed through metadata.

### How Shell handler receives cwd at execution time

Looking at the current flow: when a bash command executes, `server.ex` calls `SkillKit.Tool.Runner.run(skill_registry, input, context)`. The handler module is looked up and `execute/1` is called with a Pipeline struct containing `context`.

With the new design:
1. `SkillKit.Tools.Shell.load_kits(cwd: ".", env: [...])` stores cwd/env in the Kit's metadata
2. The kit is registered. The metadata is available on the kit in the server's `state.kits`
3. When executing a bash command, the server finds the Shell handler's kit and includes its metadata in the pipeline context
4. `SkillKit.Tools.Shell.execute/1` reads `cwd` and `env` from `pipeline.context`

This means `context` still carries `cwd` and `env` — but the server doesn't set them from `definition.workspace`. Instead, they come from the handler's kit metadata. The server's job is just to look up the handler's config and pass it through.

Actually, this is simpler than it sounds. The current `execute_command/2` in server.ex already builds context and passes it to `Handler.run`. The change is just where `cwd` comes from:

```elixir
# Before
context = %{cwd: state.definition.workspace, scope: state.scope}

# After — find Shell handler's config from kits
shell_config = find_handler_config(state.kits, SkillKit.Tools.Shell)
context = %{scope: state.scope} |> Map.merge(shell_config)
```

Where `find_handler_config` extracts `%{cwd: ..., env: ...}` from the Shell kit's metadata.

## What Changes

| Component | Change |
|-----------|--------|
| `SkillKit` | `:sources` → `:skills` in `start_agent/1`, `start_agent/2`, `start_subagent/3` |
| `SkillKit.Tools.Shell` | Rename to `SkillKit.Tools.Shell`, implement `Backend`, accept `cwd:`/`env:` config |
| `SkillKit.Agent.Definition` | Remove `:workspace` field entirely |
| `SkillKit.Agent.Server` | Stop setting `context.cwd` from definition; get handler config from kits |
| `SkillKit.Agent.Agent` | `:sources` → `:skills` in opts |
| `SkillKit.Agent.Infrastructure` | `:sources` → `:skills` |
| `SkillKit.Supervisor` | `:sources` → `:skills` |
| `SkillKit.Registry` | `:sources` → `:skills` |
| Mix tasks (chat, demo) | Use `skills:` with explicit `SkillKit.Tools.Shell` |
| Example app CLI | Update `start_agent` calls, remove workspace metadata from AGENT.md |
| Tests | Update all references to sources/workspace |

## What Doesn't Change

| Component | Reason |
|-----------|--------|
| `Backend` behaviour | Same callback |
| `Tool` | Same callbacks |
| `use SkillKit.Kit` | Same pattern (already Backend + Handler) |
| `Scope` protocol | Unaffected |
| `Skill.render` | Unaffected |
| `Catalog` | Unaffected |

## Testing

- Shell handler tests: verify cwd/env from config, default cwd to File.cwd!()
- Backend tests: Shell.load_kits returns kit with bash tool
- start_agent tests: `:skills` works, `:sources` raises helpful error
- Integration: agent with Shell in skills can execute bash commands with correct cwd
- Example app: lobby and persona chat work with new API
