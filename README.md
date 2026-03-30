# SkillKit

An Elixir library for building LLM agent systems. SkillKit provides an
application runtime where agents, skills, hooks, and subagents are defined in
markdown files and composed at startup — no framework scaffolding, no code
generation.

SkillKit's skill format is compatible with the
[Agent Skills](https://agentskills.io) open standard and aligned with the
[Claude Code plugin](https://docs.anthropic.com/en/docs/claude-code/plugins)
structure. Skills you write for SkillKit work in Claude Code, and vice versa.

## Quick Start

Add SkillKit to your dependencies:

```elixir
# mix.exs
{:skill_kit, "~> 0.1.0"}
```

Set your API key and start chatting:

```bash
export ANTHROPIC_API_KEY=sk-ant-...

# Interactive chat with a sample agent
mix skill_kit.chat neve

# Single prompt
mix skill_kit.demo "What is 2 + 2?"
```

Or use the API directly:

```elixir
# Point at a directory containing an AGENT.md
{:ok, agent} = SkillKit.start_agent("agents/neve",
  skills: ["skills", SkillKit.Tools.Shell],
  caller: self()
)

# Send a message
:ok = SkillKit.send_message(agent, "Review lib/skill_kit.ex")

# Receive streamed events
receive do
  %SkillKit.Event.Delta{text: text} -> IO.write(text)
  %SkillKit.Types.AssistantMessage{} -> IO.puts("\nDone.")
  %SkillKit.Event.Error{reason: reason} -> IO.puts("Error: #{inspect(reason)}")
end

# Stop
SkillKit.stop_agent(agent)
```

## Core Concepts

### [Agents](guides/architecture.md)

Agents are LLM-powered OTP processes defined in `AGENT.md` files with YAML
frontmatter:

```markdown
---
name: "neve"
description: "A helpful coding assistant"
model: "claude-sonnet-4-20250514"
metadata:
  max_agent_depth: 2
---
Your name is Neve. You are a helpful coding assistant.
```

Each agent starts its own supervision tree — Registry, Catalog, Mailbox,
Server, and SubagentSupervisor — fully isolated from other agents.

### [Skills](guides/skill-format.md)

Skills are markdown files that inject instructions into an agent's context.
The standard layout (from the [Agent Skills spec](https://agentskills.io/specification)
and [Claude Code plugins](https://docs.anthropic.com/en/docs/claude-code/plugins))
is a `SKILL.md` inside a named directory:

```markdown
---
name: "system:memory"
description: "Persistent memory management"
---
You have persistent memory stored in `.memory/current.md`.

At the START of every conversation, read your memory file...
```

Skills support template tokens (`$ARGUMENTS`, `$SKILL_DIR`, `$SESSION_ID`),
scope variable resolution (`$USERNAME`, `$TENANT`), and dynamic command
injection (`` !`git branch --show-current` ``) that runs at render time.

### [Hooks](guides/hooks-and-execution.md)

Skills can define hooks that fire at agent boundaries — before and after tool
use, subagent delegation, LLM requests, and more:

```yaml
hooks:
  PreToolUse:
    - matcher: "bash"
      hooks:
        - type: command
          command: "check-policy $TOOL_NAME"
  PostToolUse:
    - matcher: ".*"
      hooks:
        - type: http
          url: "https://audit.example.com/log"
```

Hooks are gate-only: they can allow, deny, or suspend a boundary crossing, but
they cannot transform data. Pre-hooks run synchronously and block the action.
Post-hooks fire asynchronously and their return values are ignored.

### [Subagents](guides/architecture.md)

Agents delegate work to child agents asynchronously. The parent invokes a
subagent as a tool call, continues its own work, and receives the result when
the child finishes:

```markdown
---
name: "code-reviewer"
description: "Reviews code for issues and reports findings"
---
You are a code reviewer. Use bash to read files, analyze them,
then call report_result with your findings.
```

Delegation depth is enforced via `max_agent_depth` in the agent definition.

### [Authorization](guides/authorization.md)

Scope-based access control restricts which skills a caller may discover and
activate. Skills declare `required_scope` in their frontmatter; callers
provide granted scopes via a struct implementing `SkillKit.Scope`.

## Loading Kits

`start_agent/2` takes an agent source as its first argument and a `skills:`
option listing additional kits. Both accept three forms:

| Form | Resolves to | Example |
|---|---|---|
| `"path"` (string) | `{SkillKit.Kit.Local, dir: "path"}` | `"skills"` loads `skills/` directory |
| `Module` (bare atom) | `{Module, []}` | `SkillKit.Tools.Shell` adds bash execution |
| `{Module, opts}` (tuple) | Used as-is | `{SkillKit.Kit.Local, dir: "/abs/path"}` |

The agent's own kit is auto-included in the tool pool. When you pass
`"agents/neve"` as the agent, its `AGENT.md` defines the identity (name,
model, system prompt) and any skills or subagents in that directory become
available tools — no need to list it again in `skills:`.

```elixir
# "agents/neve" provides the agent identity + its own skills.
# "skills" adds a shared skills directory.
# SkillKit.Tools.Shell adds bash tool execution.
SkillKit.start_agent("agents/neve",
  skills: ["skills", SkillKit.Tools.Shell],
  scope: my_scope,
  conversation_store: {SkillKit.Conversation.Store.Filesystem, path: ".conversations"}
)
```

Module-backed kits (`use SkillKit.Kit`) work the same way — they implement
both the `Kit.Provider` behaviour (to load skills from a co-located `skills/`
directory) and `Tool` (to execute them). See the
[Providers guide](guides/providers.md) for details.

## Configuration

```elixir
# config/config.exs
config :skill_kit, SkillKit.LLM,
  providers: [
    anthropic: SkillKit.LLM.Anthropic
  ],
  default_provider: :anthropic
```

## Telemetry

SkillKit emits [`:telemetry`](https://hexdocs.pm/telemetry) events for
observability and cost tracking:

| Event | Measurements | Notes |
|---|---|---|
| `[:skill_kit, :turn, :start/:stop]` | `system_time` / `duration` | One agent loop (batch of messages) |
| `[:skill_kit, :llm_request, :start/:stop]` | `system_time` / `duration` | LLM call inside a turn |
| `[:skill_kit, :tool_use, :start/:stop]` | `system_time` / `duration` | Tool or module-skill execution |
| `[:skill_kit, :subagent, :start/:stop]` | `system_time` / `duration` | Spawning a subagent |
| `[:skill_kit, :skill_activation, :start/:stop]` | `system_time` / `duration` | Activating a skill |
| `[:skill_kit, :conversation_save, :start/:stop]` | `system_time` / `duration` | Persisting conversation |
| `[:skill_kit, :conversation_load, :start/:stop]` | `system_time` / `duration` | Loading conversation |
| `[:skill_kit, :agent, :start/:stop]` | `system_time` / `duration` | Agent process lifecycle |
| `[:skill_kit, :llm, :stream, :start/:stop]` | `system_time` / `duration` | Raw LLM HTTP stream |
| `[:skill_kit, :llm, :stream, :error]` | — | Model URI could not be resolved |
| `[:skill_kit, :agent, :orphaned_result]` | — | Subagent result with no parent |
| `[:anthropic, :rate_limited]` | `retry_after`, `attempt` | 429 triggered automatic retry |

See the [Telemetry guide](guides/telemetry.md) for handler examples and
testing helpers.

## Architecture

```
SkillKit.start_agent/2
  |-> Agent (Supervisor, one_for_one)
       |-> Registry (process discovery)
       |-> Catalog (provider aggregation, authorization, tool definitions)
       |-> Core (rest_for_one)
            |-> Mailbox (message buffering)
            |-> Server (LLM loop, tool execution, streaming)
            |-> SubagentSupervisor (DynamicSupervisor)
```

Events flow: User -> `send_message` -> Mailbox -> Server -> LLM -> stream
deltas to caller -> execute tools -> loop until done -> send `AssistantMessage`.

See the [Architecture guide](guides/architecture.md) for the full supervision
tree, message flow, and module boundaries.

## Guides

- [Examples](guides/examples.md) — persona chat walkthrough, sample agents, directory structures
- [Architecture](guides/architecture.md) — supervision tree, message flow, module boundaries
- [Skill Format](guides/skill-format.md) — `SKILL.md` file format, frontmatter, template tokens, Agent Skills spec compatibility
- [Providers](guides/providers.md) — writing and registering kit providers (`Kit.Local`, `Kit.GitHub`, `Kit.Memory`, custom)
- [GitHub Import](guides/github-import.md) — importing skills from GitHub repos at runtime, reference format, allowed sources, cache
- [Hooks and Execution](guides/hooks-and-execution.md) — boundary model, hook struct, return contract, handler behaviour, built-in handlers, context maps
- [Authorization](guides/authorization.md) — scope format, authorization API, catalog integration
- [LLM Providers](guides/llm-providers.md) — adding a new LLM provider adapter
- [Conversations](guides/conversations.md) — conversation persistence and custom stores
- [Telemetry](guides/telemetry.md) — event reference, handler examples, testing

## Standards Compatibility

SkillKit's skill format is compatible with:

- **[Agent Skills](https://agentskills.io/specification)** — the open standard
  for portable agent skills. SkillKit uses the canonical `skills/skill-name/SKILL.md`
  format. Template tokens (`$ARGUMENTS`, `$SKILL_DIR`, `$SESSION_ID`) and
  progressive disclosure (metadata at discovery, full body at activation)
  follow the spec.

- **[Claude Code Plugins](https://docs.anthropic.com/en/docs/claude-code/plugins)** —
  SkillKit's `Kit.Local` directory layout aligns with the Claude Code plugin
  structure. Skills written as `skills/skill-name/SKILL.md` work in both
  systems. See the [Skill Format guide](guides/skill-format.md) for the
  mapping between SkillKit's `required_scope` and Claude Code's
  `allowed-tools` / `user-invocable` fields.

## License

MIT
