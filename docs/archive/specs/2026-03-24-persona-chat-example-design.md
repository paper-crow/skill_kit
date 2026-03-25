# Persona Chat Example App — Design Spec

## Purpose

An example CLI app that exercises SkillKit's core primitives — skills, kits, agents, conversation store, and authorization — to identify gaps and DX issues. The app lets a user create AI personas through conversation and chat with them, with per-user conversation isolation and persistent memory.

## Constraints

- Only two `.ex` files: the CLI harness and a Scope struct
- All behavior driven through skills, kits, and agent definitions
- Skills loaded from directories via `Backend.Filesystem` (no module-backed kits)

## Architecture

### Project Structure

```
examples/persona_chat/
├── lib/persona_chat/
│   ├── cli.ex                  # Mix task, stdin/stdout loop, agent switching
│   └── scope.ex                # Scope struct + SkillKit.Scope protocol impl
├── agents/
│   └── lobby/
│       └── AGENT.md            # Concierge agent for persona management
├── personas/                   # Generated at runtime
│   └── {name}/
│       └── AGENT.md
├── skills/
│   ├── persona_kit/
│   │   ├── brainstorm.skill.md
│   │   ├── develop_voice.skill.md
│   │   ├── build_backstory.skill.md
│   │   ├── finalize_persona.skill.md
│   │   ├── list_personas.skill.md
│   │   └── delete_persona.skill.md
│   └── memory_kit/
│       └── user_memory.skill.md
├── data/
│   ├── conversations/          # Per user:persona conversation stores
│   └── memories/               # Per user:persona memory files
│       └── {persona}/
│           └── {username}.md
└── mix.exs                     # Depends on :skill_kit as path dep
```

### Agents

**Lobby Agent** (`agents/lobby/AGENT.md`): System prompt instructs it to help create and manage personas. Capabilities: `activate_skill`, `bash`. Loaded with persona_kit skills via `Backend.Filesystem`.

**Persona Agents** (generated at `personas/{name}/AGENT.md`): Each has a unique system prompt encoding personality, voice, and backstory. Capabilities: `activate_skill`, `bash`. Loaded with memory_kit skills. All share the same structure — only the system prompt and name differ.

### Skill Kits

#### Persona Kit (`skills/persona_kit/`)

Multi-skill workflow for persona creation. The lobby agent chains through these with the user involved at each step — the user provides an initial spark (e.g., "something space-themed") and collaborates with the agent to shape the persona:

1. **`brainstorm`** — Given a theme, generates a list of persona concepts with short pitches. The agent presents them and the user picks one (or asks for more). This is natural conversation — the user just says "I like the second one" or "Nova sounds cool" and the agent understands the selection.
2. **`develop_voice`** — Takes the chosen concept via `$ARGUMENTS`. Develops tone, speaking style, vocabulary, quirks, catchphrases. Presents to the user for approval or refinement.
3. **`build_backstory`** — Takes concept + voice via `$ARGUMENTS`. Creates name, origin story, motivations, relationships. User can steer or approve.
4. **`finalize_persona`** — Takes all developed pieces via `$ARGUMENTS`. Writes the AGENT.md file to `personas/{name}/`.

User involvement at each step requires no code — it's purely a system prompt decision. The lobby agent's instructions tell it to present options and wait for user input before activating the next skill. The CLI is just piping messages back and forth. This makes persona creation a collaborative, conversational experience rather than a one-shot generation.

Management skills:
- **`list_personas`** — Reads `personas/` directory, returns available personas with descriptions.
- **`delete_persona`** — Removes a persona's directory. Owner-only (`required_scope: ["persona:delete"]`).

The creation skills exercise: multiple skill activations per conversation, `$ARGUMENTS` passing between skills, LLM-driven orchestration without hardcoded sequencing, user involvement via natural conversation, and small composable skill design.

#### Memory Kit (`skills/memory_kit/`)

- **`user_memory`** — Reads/writes per-user memory at `data/memories/${scope.persona}/${scope.username}.md`. Uses scope assigns for path substitution (no LLM involvement in file targeting). Instructs the persona to save facts about the user and read existing memories at conversation start.

### Conversation Isolation

Each user-persona pair gets a dedicated agent instance named `"{persona}:{username}"`. The conversation store keys off this name, producing separate history files at `data/conversations/{persona}:{username}.bin`. Same persona definition (shared personality), isolated conversation state.

### Authorization via Scope Protocol

The CLI determines owner vs visitor and constructs a scope:

```elixir
scope = %PersonaChat.Scope{
  user: "alice",
  persona: "pirate_pete",
  permissions: ["persona:chat", "persona:list"]
}

SkillKit.start_agent(definition, scope: scope)
```

The `PersonaChat.Scope` struct and `SkillKit.Scope` protocol implementation are defined in `lib/persona_chat/scope.ex` (see Gap 2 for the full implementation).

**Owner** (first user to launch the app, stored in `data/config.json`):
- Permissions: `["persona:create", "persona:delete", "persona:list", "persona:chat"]`

**Visitor** (any other `--user` value):
- Permissions: `["persona:list", "persona:chat"]`

Authorization is enforced by SkillKit's `Catalog.activate` — skills declare `required_scope` in frontmatter, the Catalog checks against `Scope.permissions(scope)`. Visitors who try to create or delete personas get an automatic unauthorized response.

### CLI Session Flow

```
mix persona_chat --user alice                        # lists personas, prompts selection
mix persona_chat --user alice --persona pirate_pete  # direct to chat
mix persona_chat --user alice --manage               # lobby for create/delete
```

**Lobby session:**
1. Start lobby agent with persona_kit skills, scoped by owner/visitor permissions
2. Owner creates personas through conversation (agent chains through creation skills autonomously)
3. `/quit` exits to persona selection or ends the program

**Persona chat session:**
1. Parse persona's AGENT.md from `personas/{name}/AGENT.md`
2. Start agent named `"{persona}:{username}"` with memory_kit skills
3. Conversation store at `data/conversations/`
4. User chats freely; persona reads/writes user memory via skill
5. `/quit` returns to selection, `/exit` ends the program

## Gaps Identified in SkillKit

### Gap 1: `activate_skill` doesn't pass arguments (blocking)

`Skill.render/2` supports `$ARGUMENTS`, `$0`, `$1` template substitution, but `Agent.Server.activate_skill/2` hardcodes an empty args map:

```elixir
# server.ex line 322
SkillKit.Catalog.activate(skill_registry, skill_name, %{}, opts)
```

The `activate_skill` tool input has no `"arguments"` field. The rendering machinery exists but isn't wired up.

**Fix:** Add an `"arguments"` field to the `activate_skill` tool input schema and pass it through to `Catalog.activate`. Small change — plumb the field through.

**Impact on example:** Blocks the multi-skill persona creation workflow (skills can't receive context from previous steps) and the memory skill (can't receive persona/user context via `$ARGUMENTS` as a fallback).

### Gap 2: No scope protocol (blocking)

Scope is currently a flat list of permission strings (`["persona:chat"]`). There is no way to carry structured identity/context through to skills and handlers.

**Fix:** Introduce a `SkillKit.Scope` protocol:

```elixir
defprotocol SkillKit.Scope do
  @type resolve_context :: %{agent: String.t(), skill: String.t()}

  @doc "Returns the list of permission strings for authorization checks"
  @spec permissions(t()) :: [String.t()]
  def permissions(scope)

  @doc "Resolves a named variable from the scope, given agent and skill context"
  @spec resolve(t(), String.t(), resolve_context()) :: {:ok, String.t()} | :error
  def resolve(scope, variable_name, context)
end
```

Move the current string validation/matching logic from `SkillKit.Scope` module into `SkillKit.Authorization`. The protocol name `SkillKit.Scope` becomes available for the new protocol.

Example implementation in the persona chat app:

```elixir
defmodule PersonaChat.Scope do
  defstruct [:user, :persona, permissions: []]
end

defimpl SkillKit.Scope, for: PersonaChat.Scope do
  def permissions(scope), do: scope.permissions

  def resolve(scope, "USERNAME", _context), do: {:ok, scope.user}
  def resolve(scope, "PERSONA", _context), do: {:ok, scope.persona}
  def resolve(scope, "WORKSPACE", %{agent: agent}) do
    {:ok, "data/memories/#{agent}"}
  end
  def resolve(_scope, _key, _context), do: :error
end
```

**Variable resolution in `Skill.render`:** Unify all template tokens under the same `$VAR` / `${VAR}` syntax (dropping the `CLAUDE_` prefix from built-ins). Resolution pipeline:

1. Built-ins: `$ARGUMENTS`, `$0`/`$1` (positional), `$SKILL_DIR`, `$SESSION_ID`
2. Scope fallback: any remaining `$VARNAME` tokens resolved via `Scope.resolve(scope, "VARNAME", %{agent: agent, skill: skill})`
3. Unresolved tokens return `:error` — SkillKit can warn rather than silently substituting empty strings

This means:
- Skills use one consistent variable syntax everywhere
- LLM-provided `$ARGUMENTS` take precedence over scope variables
- Scope resolution is context-aware (knows which agent and skill are asking)
- Skills are portable across apps — they declare variable names, the scope implementation resolves them
- The Shell handler resolves scope variables into port env vars via the same `resolve/3` call

**Impact on example:** Blocks per-user memory (skill needs username/persona for file paths) and the authorization model (scope must carry both permissions and identity).

### Gap 3: No agent handoff primitive (non-blocking)

SkillKit supports subagent delegation (parent dispatches child, gets result) but not peer handoff (agent A signals that agent B should take over the conversation).

**Workaround:** The CLI manages agent transitions directly — it stops one agent and starts another based on user commands or CLI flags. This is fine for the example app.

**Future consideration:** A handoff event or tool that an agent can emit to signal "transfer this user to agent X" would make multi-agent systems with different interaction modes more ergonomic.

### Gap 4: Shell handler context.env never populated (blocking)

The Shell handler reads `context.env` for port environment variables, but nothing in the pipeline construction writes to it. The context map is built with only `cwd` and `scope`:

```elixir
context = %{cwd: state.definition.workspace, scope: state.scope}
```

**Fix:** When building the pipeline context, resolve scope variables into `context.env` using `Scope.resolve/3`. The Shell handler already consumes `context.env` — it just needs to be populated. The pipeline construction resolves all scope variables the skill references and provides them as uppercased env var pairs to the port.

**Impact on example:** Blocks the memory skill from using scope-derived env vars in bash commands.

### Gap 5: Inconsistent variable token syntax (non-blocking, recommended)

`Skill.render/2` uses two different syntaxes: `$ARGUMENTS` (no braces) and `${CLAUDE_SESSION_ID}` (braces + `CLAUDE_` prefix). These should be unified under one convention: `$VAR` with optional `${VAR}` for boundary disambiguation. Drop the `CLAUDE_` prefix from built-ins (`$SESSION_ID`, `$SKILL_DIR`).

**Fix:** Update `Skill.render/2` to accept both `$VAR` and `${VAR}` for all variables. Rename built-ins: `${CLAUDE_SKILL_DIR}` → `$SKILL_DIR`, `${CLAUDE_SESSION_ID}` → `$SESSION_ID`. Breaking change, acceptable for pre-1.0 library.

**Impact on example:** Non-blocking (skills would use the new syntax from the start), but improves consistency for scope variable resolution which uses the same `$VAR` / `${VAR}` syntax.

## Testing Strategy

The example app is tested by running it. No unit tests for the example itself — it exists to exercise SkillKit. Gaps found during implementation feed back into SkillKit's own test suite.

## Success Criteria

1. Owner can create a persona through multi-skill conversation flow
2. Multiple users can chat with the same persona with isolated histories
3. Persona remembers facts about each user across sessions
4. Visitors cannot create or delete personas (authorization enforced)
5. Only two `.ex` files in the example app
6. Each gap identified has a clear fix path in SkillKit

## Backburner: agentskills.io Spec Alignment

Observations from comparing SkillKit with the open [Agent Skills spec](https://agentskills.io/specification). Not blocking for this example app but worth tracking for library-level alignment:

- **Filename convention:** Spec uses `SKILL.md` (uppercase, one per directory). SkillKit uses `*.skill.md` (lowercase, glob-friendly, multiple per directory). Consider supporting both or migrating.
- **Name format:** Spec requires lowercase + hyphens only (`pdf-processing`), no underscores, name must match directory name. SkillKit allows underscores in `namespace:skill_name` format. Consider supporting hyphenated names for portability.
- **Variable tokens:** `$ARGUMENTS`, `${CLAUDE_SKILL_DIR}`, etc. are Claude Code implementation details, not part of the open spec. SkillKit's variable/scope resolution is our own extension — this is fine, but document it as a SkillKit-specific feature.
- **`allowed-tools` field:** Spec has this experimental field for pre-approved tool access. SkillKit has `required_scope` which gates access differently (caller must hold scopes, vs skill declaring tools it may use). Different direction, worth watching as the spec evolves.
