# SkillKit

An Elixir framework for building LLM agent systems with skills, tools, and subagent delegation.

## Quick Start

```bash
# Set your API key
export ANTHROPIC_API_KEY=sk-ant-...

# Interactive chat
mix skill_kit.chat

# Single prompt
mix skill_kit.demo "What is 2 + 2?"
```

## What It Does

SkillKit gives you a composable agent runtime:

- **Agents** — LLM-powered processes with streaming responses, tool use, and persistent memory
- **Skills** — Markdown files that inject specialized instructions into an agent's context
- **Subagents** — Async delegation to child agents with result delivery back to the parent
- **Hooks** — Pre/post tool execution hooks for automation (e.g., memory rotation)
- **Authorization** — Scope-based access control for skills and tools

## Usage

```elixir
# Start an agent from a directory — provider discovers the root AGENT.md
{:ok, agent} = SkillKit.start_agent(
  skills: [
    {SkillKit.Kit.Local, dir: "my_agent"},
    {SkillKit.Shell, []}
  ],
  scope: my_scope,
  conversation_store: {SkillKit.Conversation.Store.Filesystem, path: ".conversations"},
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

## Agent Definitions

Agents are defined in `AGENT.md` files with YAML frontmatter:

```markdown
---
name: "neve"
description: "A helpful coding assistant"
model: "claude-sonnet-4-20250514"
capabilities: bash, activate_skill, system:memory
metadata:
  max_agent_depth: 2
---
Your name is Neve. You are a helpful coding assistant.
```

The `capabilities` field determines what the agent can do:
- **Tool names** (e.g. `bash`) register the tool with the LLM
- **Skill names** (e.g. `system:memory`) inject the skill's instructions into the system prompt
- Both can share a name (e.g. `bash` is both a tool and a skill with usage guidelines)

## Skills

Skills are `.skill.md` files with instructions that get injected into an agent's context:

```markdown
---
name: "system:memory"
description: "Persistent memory management"
---
You have persistent memory stored in `.memory/current.md`.

At the START of every conversation, read your memory file...
```

Skills can define hooks:

```yaml
hooks:
  PostToolUse:
    - matcher: ".*"
      hooks:
        - type: command
          command: "echo 'hook fired'"
```

## Subagents

Agents can delegate work to subagents asynchronously:

```markdown
---
name: "code-reviewer"
description: "Reviews code for issues and reports findings"
capabilities: bash, activate_skill, report_result
---
You are a code reviewer. Use bash to read files, analyze them,
then call report_result with your findings.
```

The parent agent calls the subagent as a tool, continues working, and receives results via a context-rich resume message.

## Telemetry Events

SkillKit emits telemetry events for observability and cost tracking:

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:skill_kit, :agent, :turn_start]` | — | `agent_name`, `message_count` |
| `[:skill_kit, :agent, :turn_end]` | `duration` | `agent_name` |
| `[:skill_kit, :agent, :response]` | — | `agent_name`, `response` |
| `[:skill_kit, :agent, :usage]` | `input_tokens`, `output_tokens` | `agent_name` |
| `[:skill_kit, :agent, :tool_call]` | — | `agent_name`, `tool_call` |
| `[:skill_kit, :agent, :tool_result]` | — | `agent_name`, `tool_call_id`, `result` |
| `[:skill_kit, :agent, :error]` | — | `agent_name`, `error` |
| `[:skill_kit, :agent, :subagent_result]` | — | `agent_name`, `subagent_name`, `task`, `result` |
| `[:skill_kit, :agent, :orphaned_result]` | — | `agent_name`, `parent_name`, `result` |
| `[:skill_kit, :llm, :rate_limited]` | `retry_after`, `attempt` | `endpoint` |

Attach handlers with `:telemetry.attach/4` or use a GenServer-based handler pattern.

## Configuration

```elixir
# LLM provider
config :skill_kit, SkillKit.LLM,
  {SkillKit.LLM.Anthropic, [api_key: System.get_env("ANTHROPIC_API_KEY")]}
```

Capabilities are registered per-agent through `skills:`. For example, to give an agent bash execution:

```elixir
SkillKit.start_agent(
  skills: [
    {SkillKit.Kit.Local, dir: ".skills"},
    {SkillKit.Shell, cwd: File.cwd!()}
  ]
)
```

## Examples

### Persona Chat

A full example app in `examples/persona_chat/` that exercises skills, kits, agents, subagent delegation, authorization, dynamic context injection, and conversation isolation. See `examples/persona_chat/README.md`.

### Sample agents and skills

```
examples/
  agents/
    neve/AGENT.md           # General-purpose coding assistant
    researcher/AGENT.md     # Research and investigation agent
    fixer/AGENT.md          # Bug fixing agent
    code-reviewer/AGENT.md  # Code review subagent
  skills/
    bash.skill.md           # Shell command guidelines
    memory.skill.md         # Persistent memory management
    code_review.skill.md    # Code review checklist
    elixir_style.skill.md  # Elixir conventions
```

Run any agent: `mix skill_kit.chat neve` or `mix skill_kit.chat researcher`

## Architecture

```
SkillKit.start_agent/1
  |-> Agent (Supervisor)
       |-> Registry (process discovery)
       |-> Infrastructure (skill registry)
       |-> Core (rest_for_one)
            |-> Mailbox (message buffering)
            |-> Server (LLM loop, tool execution, streaming)
            |-> SubagentSupervisor (DynamicSupervisor)
```

Events flow: User -> `send_message` -> Mailbox -> Server -> LLM -> Stream deltas to caller -> Execute tools -> Loop until done -> Send `:response`
