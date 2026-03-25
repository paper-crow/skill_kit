# Source-Driven start_agent — Design Spec

## Purpose

Replace the caller-parses-definition pattern with a source-driven API where `start_agent` discovers the top-level agent from backend sources. The caller provides sources and options — no Definition parsing, no manual path construction, no struct manipulation.

## Current State

```elixir
# Caller does all the work
{:ok, definition} = Definition.parse(".skills/lobby/AGENT.md")
{:ok, agent} = SkillKit.start_agent(definition,
  sources: [{Backend.Filesystem, dirs: [".skills/persona_kit"]}],
  scope: scope
)
```

Problems:
- Caller must know about `Definition` struct internals
- Agent discovery is manual (find the AGENT.md, parse it, pass it in)
- Sources for skills are separate from the agent's own source — the agent and its skills come from different paths even when they're co-located
- `Backend.Filesystem` already discovers agents alongside skills but this discovery isn't used by `start_agent`

## Design

### New API: `start_agent/1`

```elixir
# Source-driven — backend discovers everything
SkillKit.start_agent(
  sources: [
    {Backend.Filesystem, dir: ".skills"}
  ],
  scope: scope,
  conversation_store: {Store.Filesystem, path: "data/conversations"}
)
```

Options:
- `:sources` (required) — list of `{module, config}` backend sources
- `:name` — override the discovered agent's name
- `:scope` — scope for authorization and variable resolution
- `:caller` — pid to receive events (default: `self()`)
- `:conversation_store` — `{module, config}` for persistence

The existing `start_agent(definition, opts)` stays for internal subagent spawning and advanced use cases.

### Root Agent Convention

The AGENT.md at the root of a source directory is the top-level agent. Nested AGENT.md files (in subdirectories of subdirectories) are subagents.

```
.skills/                        # source directory
├── AGENT.md                    # root agent (top-level)
├── persona_kit/
│   ├── brainstorm.skill.md     # skill
│   └── persona_writer/
│       └── AGENT.md            # subagent (nested)
└── memory_kit/
    └── user_memory.skill.md    # skill
```

Rules across all sources:
- Exactly one root agent → use it as top-level
- Zero root agents → `{:error, :no_agent_found}`
- Multiple root agents → `{:error, :multiple_root_agents}`

### Backend.Filesystem Change

`dirs:` (plural list) becomes `dir:` (singular string). One backend entry, one directory. Multiple directories require multiple source entries:

```elixir
# Before
sources: [{Backend.Filesystem, dirs: [".skills", "personas/captain_nova"]}]

# After
sources: [
  {Backend.Filesystem, dir: ".skills"},
  {Backend.Filesystem, dir: "personas/captain_nova"}
]
```

The backend must return metadata indicating which agents are root-level (discovered at the root of the dir) vs nested (in subdirectories). This could be:
- A field on `Kit.t()` marking which agents are root-level
- A field on `Definition.t()` like `:root` (boolean)
- Position-based: root agents are returned in `kit.agents` only when found at the dir root

### Discovery Flow

When `start_agent/1` is called:

1. Load all kits from all sources via existing `Backend.load_kits` mechanism
2. Collect all agent definitions from returned kits
3. Partition into root agents vs subagents (based on backend metadata)
4. Validate: exactly one root agent exists
5. Use the root agent's definition to start the agent
6. All skills from all kits are registered (merged across sources)
7. All subagent definitions are available for delegation

### Example App Usage

```elixir
# Lobby — one source contains the agent, skills, and subagents
SkillKit.start_agent(
  sources: [{Backend.Filesystem, dir: ".skills"}],
  scope: scope
)

# Persona chat — persona dir has the agent, memory_kit has skills
SkillKit.start_agent(
  sources: [
    {Backend.Filesystem, dir: "personas/valentina_restrepo"},
    {Backend.Filesystem, dir: ".skills/memory_kit"}
  ],
  name: "valentina_restrepo:alice",
  scope: scope,
  conversation_store: {Store.Filesystem, path: "data/conversations"}
)
```

### Example App Restructure

```
examples/persona_chat/
├── lib/persona_chat/
│   ├── cli.ex
│   └── scope.ex
├── .skills/
│   ├── AGENT.md                # lobby (was .skills/lobby/AGENT.md)
│   ├── persona_kit/
│   │   ├── brainstorm.skill.md
│   │   ├── develop_voice.skill.md
│   │   ├── build_backstory.skill.md
│   │   ├── finalize_persona.skill.md
│   │   ├── list_personas.skill.md
│   │   ├── delete_persona.skill.md
│   │   └── persona_writer/
│   │       └── AGENT.md
│   └── memory_kit/
│       └── user_memory.skill.md
├── personas/
│   └── {name}/
│       └── AGENT.md            # root agent for this source dir
├── data/
└── mix.exs
```

## What Changes

| Component | Change |
|-----------|--------|
| `SkillKit` | New `start_agent/1` clause accepting keyword list only |
| `Backend.Filesystem` | `dirs:` → `dir:` (singular); mark root vs nested agents in returned kits |
| `Backend` behaviour | May need return type adjustment to carry root/nested metadata |
| `Kit` struct or `Definition` struct | Needs a way to flag root agents |
| Example app | Restructure `.skills/`, update CLI to use new API |

## What Doesn't Change

| Component | Reason |
|-----------|--------|
| `start_agent(definition, opts)` | Stays for internal subagent spawning |
| `Skill`, `Scope`, `Catalog`, `Handler` | Not affected |
| Subagent spawning internals | Still uses Definition structs |
| Conversation Store, Authorization | Not affected |

## Testing Strategy

- Unit tests for `start_agent/1`: single source with root agent, multiple sources with one root, zero root agents error, multiple root agents error
- Unit tests for `Backend.Filesystem` with `dir:` (singular): root agent detection, nested agent detection
- Integration test: start agent from sources, verify skills are registered and subagents are available
- Example app: verify lobby and persona chat both work with new API
