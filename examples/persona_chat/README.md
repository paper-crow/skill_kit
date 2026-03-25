# Persona Chat

An example app that exercises SkillKit's core primitives — skills, kits, agents, conversation store, authorization, and subagent delegation.

Users create AI personas through conversation, then chat with them. Each user gets isolated conversation history and the persona remembers things about each user across sessions.

## What it exercises

| SkillKit Feature | How it's used |
|---|---|
| **Skills** | 7 skills across 2 kits drive all behavior (brainstorming, voice development, memory, etc.) |
| **Kits via Backend.Filesystem** | Skills loaded from directories — no module-backed kits, no `.ex` files beyond the CLI |
| **Agent definitions** | Lobby agent + dynamically created persona agents, all from AGENT.md files |
| **Subagent delegation** | Lobby delegates file writing to a `persona_writer` subagent |
| **Conversation store** | Per-user conversation isolation via agent naming (`persona:username`) |
| **Scope protocol** | Owner vs visitor authorization, plus `$USERNAME`/`$PERSONA` variable resolution in skills |
| **activate_skill with arguments** | Multi-skill chaining — output of one skill feeds as `$ARGUMENTS` to the next |

## Setup

```bash
cd examples/persona_chat
mix deps.get
```

Requires `ANTHROPIC_API_KEY` in your environment (or in `.env` at the project root).

## Usage

### Create a persona

```bash
mix persona_chat --user alice --manage
```

The first user to run the app becomes the **owner** and can create/delete personas. Tell the lobby agent a theme (e.g., "something space-themed") and it will walk you through persona creation:

1. **Brainstorm** — generates persona concepts, you pick one
2. **Develop voice** — builds tone, quirks, speaking style
3. **Build backstory** — creates name, origin, motivations
4. **Finalize** — delegates to a subagent that writes the AGENT.md file

### Chat with a persona

```bash
mix persona_chat --user alice --persona persona_name
```

Or omit `--persona` to see a list and pick one:

```bash
mix persona_chat --user alice
```

### Multi-user isolation

Open two terminals:

```bash
# Terminal 1
mix persona_chat --user alice --persona captain_nova

# Terminal 2
mix persona_chat --user bob --persona captain_nova
```

Alice and Bob talk to the same persona (same personality, same system prompt) but have completely separate conversation histories and memory files. Captain Nova remembers Alice's favorite color without Bob ever knowing about it.

### Visitor access

```bash
mix persona_chat --user bob --manage
```

Bob can list personas but cannot create or delete them — the Scope protocol assigns visitor permissions (`persona:list`, `persona:chat`) vs owner permissions (`persona:create`, `persona:delete`, `persona:list`, `persona:chat`).

## Project structure

```
examples/persona_chat/
├── lib/persona_chat/
│   ├── cli.ex              # CLI harness — the only app logic
│   └── scope.ex            # Scope struct + SkillKit.Scope protocol impl
├── .skills/
│   ├── lobby/
│   │   └── AGENT.md        # Management agent
│   ├── persona_kit/
│   │   ├── brainstorm.skill.md
│   │   ├── develop_voice.skill.md
│   │   ├── build_backstory.skill.md
│   │   ├── finalize_persona.skill.md
│   │   ├── list_personas.skill.md
│   │   ├── delete_persona.skill.md
│   │   └── persona_writer/
│   │       └── AGENT.md    # Subagent for silent file writing
│   └── memory_kit/
│       └── user_memory.skill.md
├── personas/               # Generated at runtime
├── data/
│   ├── conversations/      # Per user:persona conversation files
│   └── memories/           # Per user:persona memory files
└── mix.exs
```

Only two `.ex` files. Everything else is markdown — agent definitions and skill templates that SkillKit loads and executes.

## SkillKit gaps identified

Building this app surfaced these library gaps (some already fixed in this branch):

1. **activate_skill arguments** — `$ARGUMENTS` rendering existed but wasn't wired through the server. Fixed.
2. **Scope protocol** — Scope was a flat permission list. Now it's a protocol carrying identity, permissions, and variable resolution. Fixed.
3. **Variable syntax** — Inconsistent `$ARGUMENTS` vs `${CLAUDE_SKILL_DIR}`. Unified to `$VAR`/`${VAR}` with scope fallback. Fixed.
4. **Agent handoff** — No way for one agent to transfer a conversation to another. The CLI works around this by managing agent lifecycle directly.
5. **Lobby conversation persistence** — Persisting lobby conversations caused the agent to resume mid-roleplay. Lobby now starts fresh each session.
6. **System prompt boundaries** — LLMs will fill instruction gaps by doing what seems helpful (e.g., roleplaying as a persona it just created). Explicit "you CANNOT do X" instructions are essential.
