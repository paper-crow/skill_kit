# Provider list_kits/get_kit and Catalog Redesign

**Date:** 2026-03-25
**Status:** Draft

## Overview

Replace the current `load_kits/1` provider callback, ETS-backed Registry, Infrastructure, and Catalog with a unified model: providers implement `list_kits/1` and `get_kit/2` to return kits (packages of skills, agents, hooks), and a single `SkillKit.Catalog` aggregates across providers, unpacks kits, handles authorization, and exposes `list/get` to the agent.

Providers are the store. The Catalog is the lens. Skills are always fresh because the agent always asks providers through the Catalog. No caching in the Catalog — providers manage their own cache lifecycle.

## Design Decisions

1. **`list_kits/1` + `get_kit/2` replace `load_kits/1`** — providers return kits on demand, not everything at startup
2. **Kits are packages** — a Kit contains skills, agents, hooks, metadata. Providers return kits, the Catalog unpacks them.
3. **Provider caches internally** — expensive work (filesystem parsing) is the provider's responsibility to cache
4. **No watch/observable mechanism** — the agent calls `list` on every run via the Catalog, so it always sees the latest
5. **Catalog replaces Registry + Infrastructure + Catalog** — one module between the agent and providers
6. **Progressive disclosure** — Catalog `list_skills` returns `{name, description}` for tool definitions, `get_skill` returns the full skill on activation
7. **Telemetry for external consumers** — skill events emitted via telemetry for cross-node sync, monitoring

## Provider Behaviour

The current behaviour:

```elixir
# CURRENT — replaced by this design
@callback load_kits(config :: keyword()) :: {:ok, [Kit.t()]} | {:error, term()}
```

The new behaviour:

```elixir
@callback list_kits(config :: keyword()) :: {:ok, [Kit.t()]} | {:error, term()}
@callback get_kit(config :: keyword(), name :: String.t()) :: {:ok, Kit.t()} | {:error, :not_found}
```

**`list_kits/1`** — returns all kits this provider knows about. Each kit is a package containing skills, agents, hooks, etc.

**`get_kit/2`** — returns a single kit by name.

Providers are responsible for their own caching. Kit.Local may cache parsed kits keyed by file content hash. Kit.Memory returns from its Agent state.

**Error handling across providers:** When the Catalog calls `list_kits/1` on multiple providers and one fails, it logs the error and returns results from the successful providers. Partial results are better than no results.

## Kit Struct

A kit is a package — the equivalent of a Claude plugin:

```elixir
%Kit{
  name: "persona_kit",
  skills: [%Skill{}, ...],
  agents: [%Definition{}, ...],
  hooks: [%Hook{}, ...],
  root_agent: %Definition{} | nil,
  metadata: %{}
}
```

The Kit struct stays in the provider interface. Providers return kits. The Catalog unpacks them into skills, agents, hooks for the agent to consume.

## Provider Implementations

### Kit.Memory

In-memory provider backed by an `Agent`. No filesystem, no cleanup. Ideal for tests and dynamic skill injection.

```elixir
{:ok, provider} = Kit.Memory.start_link([])

# Store a full kit
Kit.Memory.put_kit(provider, %Kit{name: "my_kit", skills: [...], agents: [...]})

# Or convenience for single skills (wraps in a kit internally)
Kit.Memory.put(provider, %Skill{name: "hello", ...})
Kit.Memory.delete(provider, "hello")

# Provider callbacks:
Kit.Memory.list_kits(provider: pid)           # → {:ok, [%Kit{}, ...]}
Kit.Memory.get_kit(provider: pid, "my_kit")   # → {:ok, %Kit{}} | {:error, :not_found}
```

### Kit.Local

Filesystem provider. Reads `.skill.md` and `AGENT.md` files from a directory, returns them as a kit.

```elixir
Kit.Local.list_kits(dir: "/path/to/skills")          # → {:ok, [%Kit{}]}
Kit.Local.get_kit(dir: "/path/to/skills", "my_kit")  # → {:ok, %Kit{}} | {:error, :not_found}
```

Internally caches parsed kits keyed by file content hash. Re-reads the directory on `list_kits`, re-parses only changed files.

### use SkillKit.Kit macro

The `use SkillKit.Kit` macro currently generates `load_kits/1`. Updated to generate `list_kits/1` and `get_kit/2` instead.

## Catalog

`SkillKit.Catalog` sits between the agent and providers. It aggregates kits from all providers, unpacks them into skills/agents/hooks, handles authorization, builds tool definitions for the LLM, and classifies tool calls back to the right handler.

This single module replaces the current `SkillKit.Registry` (ETS), `Agent.Infrastructure`, `SkillKit.Catalog`, and `Agent.ToolBuilder`.

### How It Works

```
Catalog.list_skills(catalog):
  → calls list_kits/1 on each configured provider
  → unpacks all kits into skills
  → builds name→{provider, kit_name} routing index
  → filters by authorization (scope)
  → returns [{name, description}, ...] for tool definitions

Catalog.get_skill(catalog, skill_name):
  → looks up {provider, kit_name} in routing index
  → calls get_kit/2 on that provider
  → finds the skill in the kit
  → checks authorization
  → returns {:ok, %Skill{}} or error

Catalog.list_agents(catalog):
  → returns agent definitions from all loaded kits

Catalog.get_agent(catalog, agent_name):
  → looks up agent definition across kits
```

### Routing Index

The Catalog maintains a lightweight routing index built from the last `list_skills` call. It maps skill names to `{provider_module, provider_config, kit_name}` — not to skills. When `get_skill` is called, the Catalog knows which provider and kit to ask. This index is rebuilt on every `list_skills` call.

### Public API

```elixir
# Skills
Catalog.list_skills(catalog)
# → [{name :: String.t(), description :: String.t()}, ...]

Catalog.get_skill(catalog, name)
# → {:ok, Skill.t()} | {:error, :not_found} | {:error, :unauthorized}

# Agent definitions
Catalog.list_agents(catalog)
# → [Definition.t()]

Catalog.get_agent(catalog, name)
# → {:ok, Definition.t()} | {:error, :not_found}

# Hooks
Catalog.hooks(catalog)
# → [Hook.t()]

# LLM integration (replaces ToolBuilder)
Catalog.tool_definitions(catalog)
# → [ToolDefinition.t()] — ready to send to the LLM

Catalog.classify(catalog, tool_name)
# → :skill | :handler | :agent | :builtin
```

### What Catalog replaces

| Current | New |
|---|---|
| `SkillKit.Registry` (ETS-backed skill lookup) | `Catalog.get_skill/2` delegates to providers via routing index |
| `SkillKit.Catalog` (authorization + listing) | Same module, expanded to handle aggregation |
| `Agent.Infrastructure` (loads kits, registers skills) | `Catalog` aggregates providers on demand |
| `Agent.ToolBuilder` (builds tool defs + classifier) | `Catalog.tool_definitions/1` + `Catalog.classify/2` |
| `Kit.Provider.load_kits/1` | `Kit.Provider.list_kits/1` + `Kit.Provider.get_kit/2` |

### Supervision Tree

```
Agent (Supervisor)
├── Catalog               (replaces Registry + Infrastructure + old Catalog + ToolBuilder)
└── Core (rest_for_one)
    ├── Mailbox
    ├── Server
    └── SubagentSupervisor
```

Initialized with provider configs and the agent's scope:

```elixir
{SkillKit.Catalog, providers: [{Kit.Local, dir: ".skills"}, {Kit.Memory, provider: pid}], scope: scope}
```

### Authorization

Catalog checks authorization on both `list_skills` and `get_skill`:
- `list_skills` filters out skills the agent's scope doesn't have access to
- `get_skill` returns `{:error, :unauthorized}` if scope doesn't cover `required_scope`

Resolves the agent's scope to permissions via `SkillKit.Scope.permissions/1`, then uses `SkillKit.Authorization.authorized?/2`.

### Call Frequency

`list_skills` is called when `ToolBuilder.build_tools/2` runs — once per agent loop iteration. This calls `list_kits` on every provider. Providers must treat `list_kits` as a hot path. Kit.Memory is inherently fast. Kit.Local should cache parsed results and only re-parse changed files.

## Telemetry

Skill events emitted via telemetry for external consumers:

```elixir
:telemetry.execute([:skill_kit, :skill, :activated], %{}, %{skill: name, agent: agent_name})
:telemetry.execute([:skill_kit, :skill, :listed], %{count: n}, %{agent: agent_name})
```

A future PubSub adapter could listen to telemetry and broadcast across nodes. This is the extension point for distributed sync.

## Impact on Existing Code

### Kit struct

Stays in the provider interface — it's the package format. No longer cached in ETS. Providers return kits, Catalog unpacks them.

### SkillKit.Supervisor

Currently starts a `SkillKit.Registry`. Removed — the Catalog is started per-agent in the agent supervision tree.

### Agent.Server

Simplified — the Server talks to the Catalog for everything:
- Tool definitions: `Catalog.tool_definitions/1` (replaces `ToolBuilder.build_tools/2`)
- Tool call routing: `Catalog.classify/2` (replaces `ToolBuilder.classifier/2`)
- Skill activation: `Catalog.get_skill/2`
- Subagent discovery: `Catalog.get_agent/2`
- Hook collection: `Catalog.hooks/1`
- Handler discovery: uses `Skill.handler` field (already on the struct)

### Agent.ToolBuilder

Removed. Its responsibilities are absorbed by the Catalog:
- `build_tools/2` → `Catalog.tool_definitions/1`
- `classifier/2` → `Catalog.classify/2`
- `skill_short_name/1` — moves to `Skill` module or Catalog internals

### start_agent

The source-driven `start_agent/1` currently loads all kits upfront. New model:
- Provider configs passed to Catalog
- Root agent discovery: Catalog calls `list_kits` on providers, finds the kit with a `root_agent` set
- No upfront `load_kits` call

## Migration Path

1. Add `list_kits/1` and `get_kit/2` to `Kit.Provider` behaviour
2. Implement in Kit.Local (alongside existing `load_kits` temporarily) and Kit.Memory (new)
3. Update `use SkillKit.Kit` macro to generate new callbacks
4. Build new `SkillKit.Catalog` (GenServer with provider configs, scope, routing index)
5. Update Agent.Server to use Catalog (replaces both kit-based lookups and ToolBuilder)
6. Update `start_agent/1` for root agent discovery via Catalog
7. Remove `Agent.Infrastructure`, ETS-backed `Registry`, old `Catalog`, `ToolBuilder`, and `load_kits/1`
