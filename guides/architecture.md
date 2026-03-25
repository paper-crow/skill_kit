# Architecture Overview

SkillKit is an Elixir framework for building LLM agent systems. Each agent is
an isolated OTP supervision tree that buffers messages, drives an LLM loop,
executes tools, and streams events back to the caller process.

## Agent Lifecycle

The public API follows a three-step pattern:

```elixir
{:ok, agent} = SkillKit.start_agent(definition, sources: [...], caller: self())
:ok          = SkillKit.send_message(agent, "Hello")
# ... receive events in caller process ...
:ok          = SkillKit.stop_agent(agent)
```

`start_agent/2` builds an `AgentRef` — an opaque struct holding the agent name,
a unique Registry name, and the supervisor PID. `send_message/2` routes to the
Mailbox via Registry lookup. `stop_agent/1` calls `Supervisor.stop/1` on the
root supervisor, tearing down the entire tree.

## Supervision Tree

Each agent owns its own Registry and two isolated supervisor subtrees under a
top-level `:one_for_one` supervisor:

```
SkillKit.Agent (one_for_one)
├── Registry              (process discovery for this agent)
├── Agent.Infrastructure  (one_for_one)
│   └── SkillKit.Supervisor  (skill registry + providers)
└── Agent.Core            (rest_for_one)
    ├── Agent.Mailbox         (message buffering)
    ├── Agent.Server          (LLM loop + tool execution)
    └── Agent.SubagentSupervisor  (DynamicSupervisor)
```

**Infrastructure** is isolated from **Core** intentionally: a skill registry
crash does not restart the conversation. Within Core, `:rest_for_one` ordering
ensures that if Mailbox crashes, Server and SubagentSupervisor both restart
(a Server without a Mailbox is useless); if Server crashes, SubagentSupervisor
also restarts (orphaned subagents should not continue running).

Mailbox resolves Server via Registry lookup at flush time rather than at init,
which avoids start-order coupling within the `:rest_for_one` chain.

## Message Flow

```
caller process
    |
    | SkillKit.send_message/2
    v
Agent.Mailbox  (buffers until size threshold or flush interval)
    |
    | {:mailbox_flush, messages}
    v
Agent.Server   (handle_info drives the synchronous LLM loop)
    |
    | SkillKit.LLM.stream/2
    v
LLM Provider   (HTTP stream)
    |
    | Delta chunks decoded as they arrive
    v
caller process  <-- %Event.Delta{}, %Event.ToolCallStart{}, etc.
```

The Mailbox batches messages by size or time before forwarding, decoupling
`send_message/2` (which is a `GenServer.cast`) from LLM call timing. The Server
drives the entire turn synchronously inside a single `handle_info` callback —
there is no concurrent LLM call state to manage.

## Tool Execution Loop

After receiving a streamed LLM response, the Server checks for tool calls and
loops until the model returns a response with no tools:

```
Server receives {:mailbox_flush, messages}
  │
  └─► call LLM, stream response to caller
        │
        ├─ if no tool calls → send %AssistantMessage{} to caller, done
        │
        └─ if tool calls present:
               │
               ├─ classify each call: local tool / subagent / halt
               ├─ execute local tools via Handler (authorized by Scope)
               ├─ collect results as %ToolResult{} structs
               └─ append results to message history, loop ↑
```

Tool calls are classified by the Server before execution. Local tools are
dispatched to the configured Handler. The loop continues until the LLM responds
with no tool calls or a halt condition is reached.

## Subagents

An agent can delegate work to a child agent by invoking a subagent tool call.
The Server spawns the child under its `SubagentSupervisor`, monitors the child
supervisor PID, and continues its own turn. When the child calls `report_result`
or terminates, it delivers its result back to the parent Server via the parent's
Registry. The parent resumes with a synthesised tool result in its message
history.

Delegation depth is enforced by comparing `depth` against
`definition.metadata.max_agent_depth`. Subagents start with `depth + 1` and
have no direct caller process — they communicate only through the parent Registry.

## Key Module Boundaries

| Concern | Where to look |
|---|---|
| LLM providers (Anthropic, etc.) | `SkillKit.LLM` and `SkillKit.LLM.Anthropic` |
| Skill loading (filesystem, etc.) | `SkillKit.Kit.Provider` behaviours |
| Tool execution + hooks | `SkillKit.Handler` behaviour |
| Authorization + scope | `SkillKit.Authorization` |
| Observability | `SkillKit.Telemetry` |

See the dedicated guide pages for each of these boundaries for configuration
details and extension points.
