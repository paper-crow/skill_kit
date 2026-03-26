# Persona Chat

An example app that exercises SkillKit's core primitives — skills, kits, agents, conversation store, authorization, subagent delegation, and dynamic context injection.

Users create AI personas through conversation, then chat with them. Each user gets isolated conversation history and the persona remembers things about each user across sessions.

## What it exercises

| SkillKit Feature | How it's used |
|---|---|
| **Agent identity** | `start_agent("agents/lobby", ...)` loads AGENT.md from the directory — agent identity is the first argument |
| **Skills** | 7 skills across 2 kits drive all behavior (brainstorming, voice development, memory, etc.) |
| **SkillKit.Shell as Kit** | Shell handler registered through `skills:` like any other kit |
| **Kit.Local** | Skills and agents loaded from directories via string paths (resolved to `Kit.Local`) |
| **Root agent convention** | AGENT.md at root of source dir is the top-level agent; nested agents are subagents |
| **Subagent delegation** | Lobby delegates file writing to a `persona_writer` subagent |
| **Dynamic context injection** | `` !`command` `` in skills runs at render time, injecting live data (persona list, user memories) |
| **Conversation store** | Per-user conversation isolation via agent naming (`persona:username`) |
| **Scope protocol** | Owner vs visitor authorization, plus `$USERNAME`/`$PERSONA` variable resolution in skills and system prompts |
| **activate_skill with arguments** | Multi-skill chaining — output of one skill feeds as `$ARGUMENTS` to the next |

## Setup

```bash
cd examples/persona_chat
mix deps.get
```

Requires `ANTHROPIC_API_KEY` in your environment.

## Usage

### Create a persona

```bash
mix persona_chat --user alice --manage
```

The first user to run the app becomes the **owner** and can create/delete personas. Tell the lobby agent a theme (e.g., "something space-themed") and it will walk you through persona creation:

1. **Brainstorm** — generates persona concepts, you pick one
2. **Develop voice** — builds tone, quirks, speaking style
3. **Build backstory** — creates name, origin, motivations
4. **Finalize** — delegates to a `persona_writer` subagent that writes the AGENT.md file silently

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
├── agents/
│   ├── lobby/
│   │   ├── AGENT.md        # Lobby — root agent for management
│   │   ├── agents/
│   │   │   └── persona-writer.md  # Subagent for silent file writing
│   │   └── skills/
│   │       ├── brainstorm/SKILL.md
│   │       ├── develop-voice/SKILL.md
│   │       ├── build-backstory/SKILL.md
│   │       ├── finalize-persona/SKILL.md
│   │       ├── list-personas/SKILL.md
│   │       └── delete-persona/SKILL.md
│   └── personas/           # Generated at runtime
│       └── valentina_restrepo/AGENT.md
├── skills/
│   └── user-memory/SKILL.md
├── data/
│   ├── conversations/      # Per user:persona conversation files
│   └── memories/           # Per user:persona memory files
└── mix.exs
```

Only two `.ex` files. Everything else is markdown — agent definitions and skill templates that SkillKit loads and executes.

## Key SkillKit features demonstrated

### Agent identity separate from tools

The CLI passes the agent directory as the first argument to `start_agent`, and additional skill directories as the `skills:` option:

```elixir
# Lobby — agents/lobby/ contains AGENT.md at root + all skills
SkillKit.start_agent("agents/lobby",
  skills: ["skills", SkillKit.Shell],
  scope: scope
)

# Persona — persona dir has AGENT.md, skills dir has shared skills
SkillKit.start_agent("agents/personas/valentina_restrepo",
  skills: ["skills", SkillKit.Shell],
  name: "valentina_restrepo:alice",
  scope: scope,
  conversation_store: {SkillKit.Conversation.Store.Filesystem, path: "data/conversations"}
)
```

### Dynamic context injection

Skills use `` !`command` `` to inject live data at render time. The command runs during `Skill.render` — the LLM sees actual data, not scripts to execute.

```markdown
## Available personas
!`for dir in agents/personas/*/; do ... done`
```

The LLM receives the persona list directly. No bash tool call needed for read operations.

### Scope-based variable resolution

The `SkillKit.Scope` protocol resolves `$USERNAME` and `$PERSONA` in both skill bodies and system prompts:

```markdown
To chat: `mix persona_chat --user $USERNAME --persona PERSONA_NAME`
```

Renders as `mix persona_chat --user alice --persona PERSONA_NAME` — the LLM sees the real username.

### Per-user memory

The `user_memory` skill uses dynamic injection to read existing memories and scope variables for file paths:

```markdown
## What you remember about this user
!`cat data/memories/$PERSONA/$USERNAME.md 2>/dev/null || echo "No memories yet."`
```

Memories are injected at skill activation — the persona starts each conversation already knowing what it learned before.

## DX findings

Building this app surfaced these insights:

1. **Skills with code blocks get treated as documentation** — LLMs display bash scripts rather than executing them. Dynamic injection (`` !`command` ``) solves the read case. Write operations still need explicit "run this command" instructions.
2. **System prompt boundaries matter** — LLMs fill instruction gaps with what seems helpful (e.g., roleplaying as a persona it just created). Explicit "you CANNOT do X" is as important as "you can do Y."
3. **Lobby conversations shouldn't persist** — Management agents should start fresh each session. Persisted conversations caused the lobby to resume mid-roleplay.
4. **Agent handoff is a gap** — No way for one agent to signal "transfer to agent B." The CLI manages transitions directly.
5. **Missing API key causes silent hang** — The CLI now validates `ANTHROPIC_API_KEY` at startup with a clear error message.
