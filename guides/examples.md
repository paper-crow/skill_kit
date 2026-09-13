# Examples

## Persona Chat

A full example app in `examples/persona_chat/` that exercises most of
SkillKit's primitives. Users create AI personas through conversation, then
chat with them — each user gets isolated conversation history and per-user
memory.

```bash
cd examples/persona_chat
mix deps.get

# Create personas (first user becomes owner)
mix persona_chat --user alice --manage

# Chat with a persona
mix persona_chat --user alice --persona captain_nova
```

### What it exercises

| Feature | How |
|---|---|
| Agent identity | `AGENT.md` at root of each agent directory |
| Skills | 7 skills across lobby and memory kits drive all behavior |
| Subagent delegation | Lobby delegates file writing to a `persona_writer` subagent |
| Dynamic context injection | `` !`command` `` in skills runs at render time (opt-in via `config :skill_kit, :allow_dynamic_commands, true`), injecting live persona lists and user memories |
| Conversation persistence | Per-user conversation isolation via `Conversation.Store.Filesystem` |
| Scope-based authorization | Owner vs visitor permissions — owners create/delete, visitors chat |
| Scope variable resolution | `$USERNAME` and `$PERSONA` replaced in skill bodies and system prompts |
| Shell tool as kit | `SkillKit.Tools.Shell` registered alongside filesystem kits |

Only two `.ex` files in the example. Everything else is markdown.

See [`examples/persona_chat/README.md`](../examples/persona_chat/README.md) for
the full walkthrough.

### Directory structure

```
examples/persona_chat/
├── agents/
│   ├── lobby/                          # Lobby kit — identity + creation tools
│   │   ├── AGENT.md
│   │   ├── skills/
│   │   │   ├── brainstorm/SKILL.md
│   │   │   ├── develop-voice/SKILL.md
│   │   │   ├── build-backstory/SKILL.md
│   │   │   ├── finalize-persona/SKILL.md
│   │   │   ├── list-personas/SKILL.md
│   │   │   └── delete-persona/SKILL.md
│   │   └── agents/
│   │       └── persona-writer.md
│   └── personas/
│       └── valentina_restrepo/
│           └── AGENT.md
├── skills/                             # Shared skills
│   └── user-memory/SKILL.md
├── data/
└── lib/persona_chat/
    ├── cli.ex
    └── scope.ex
```

### How it uses `start_agent`

```elixir
# Lobby — identity from lobby kit, shared skills added separately
SkillKit.start_agent("agents/lobby",
  skills: ["skills", SkillKit.Tools.Shell],
  scope: scope
)

# Persona — identity from persona kit, shared skills composed in
SkillKit.start_agent("agents/personas/valentina_restrepo",
  skills: ["skills", SkillKit.Tools.Shell],
  name: "valentina_restrepo:sam",
  scope: scope,
  conversation_store: {SkillKit.Conversation.Store.Filesystem, path: "data/conversations"}
)
```

The lobby kit provides agent identity AND its own skills (brainstorm, develop-voice, etc.)
via the first argument. The persona kit provides only identity — shared tools come from
the `skills:` option. No tool inheritance conflict.

## Sample Agents and Skills

```
examples/
  agents/
    neve/AGENT.md           # General-purpose coding assistant
    researcher/AGENT.md     # Research and investigation agent
    fixer/AGENT.md          # Bug fixing agent
    code-reviewer/AGENT.md  # Code review subagent
  skills/
    bash/SKILL.md           # Shell command guidelines
    memory/SKILL.md         # Persistent memory management
    code_review/SKILL.md    # Code review checklist
    elixir_style/SKILL.md   # Elixir conventions
```

Run any agent: `mix skill_kit.chat neve` or `mix skill_kit.chat researcher`
