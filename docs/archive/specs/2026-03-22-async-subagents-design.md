# Async Subagent Delegation Design

## Problem

Subagent delegation in the Server is a placeholder — it returns "not yet implemented." The SubagentSupervisor, process monitoring, and result injection via `handle_info` are all built, but nothing actually spawns a child agent.

## Design

### Spawning

When the LLM calls a subagent tool (e.g. `code-reviewer(task: "review lib/skill_kit.ex")`), the Server:

1. Finds the matching `%Definition{}` from `state.kits` by name
2. Generates a unique subagent name: `"parent-name/code-reviewer-<unique_int>"` — avoids Registry key collisions
3. Starts a new agent via `SkillKit.start_agent/2` — the subagent is an **independent agent**, not a child of the parent's supervision tree
4. The child gets: its own definition (with overridden name from step 2), the same sources/provider, `depth + 1`, and the parent's agent name as `parent_name`
5. Each subagent gets its **own Registry** — standard `SkillKit.start_agent` behavior, no sharing needed
6. Looks up the child's Server pid via the child's Registry and monitors it
7. Sends the task as the child's first message via `SkillKit.send_message/2`
8. Returns an immediate `ToolResult`: `"Delegated to code-reviewer. You will receive the result when it completes."`
9. Stores `{server_pid => %{name: name, task: task, monitor_ref: ref, parent_intent: last_assistant_text, agent_ref: agent_ref}}` in `state.subagents` — keyed by the child's **Server pid**

The `parent_intent` is the content from the current `%Assistant{}` response (the one that contained the tool call). This captures what the LLM was planning to do when it delegated.

The subagent runs asynchronously — the parent's tool call returns immediately and the agent loop continues.

### Independent Lifecycle

Subagents are **independent agents** started via the public API, not children of the parent's supervision tree. This means:

- **Parent crash doesn't kill subagents.** If the parent crashes and restarts, subagents continue running and finish their work.
- **Results survive parent restarts.** When a subagent calls `report_result`, it looks up the parent by name. If the parent restarted (new pid, same name), the result still arrives because the lookup uses the parent's agent name, not a stored pid.
- **Clean separation.** No Registry sharing, no conditional init logic. Each agent is a self-contained unit with its own Registry, Infrastructure, and Core.

The `SubagentSupervisor` (DynamicSupervisor) in the parent's tree is **not used** for spawning. It remains available for future use cases (e.g., supervised subagent pools) but subagents in v1 are independent.

The parent stores the `%AgentRef{}` in its subagents map so it can stop subagents via `SkillKit.stop_agent/1` during cleanup.

### Parent Lookup for report_result

The subagent needs to find its parent's Server pid to send results. Since the subagent has `parent_name` in state, and we need a way to find the parent's Server in a different Registry:

Option: pass the parent's Registry name to the subagent via a new `parent_registry` field in the opts. The subagent stores this in state. When `report_result` fires, it does `Registry.lookup(parent_registry, {parent_name, :server})`.

If the lookup returns `[]` (parent is gone or restarting), the result is emitted via telemetry and the subagent halts gracefully.

### Subagent Completion via `report_result`

The subagent has `report_result` as a builtin tool (already defined in ToolBuilder when `subagent: true`). The flow:

1. Subagent calls `report_result(result: "Found 3 issues: ...")`
2. Server handles it as a `:builtin` in `execute_tool_calls` — the builtin handler receives state (change from current placeholder pattern)
3. Looks up the parent's Server pid via `Registry.lookup(parent_registry, {parent_name, :server})`
4. Sends `{:subagent_result, self(), result_text}` to the parent
5. Returns a ToolResult to the subagent: `"Result reported successfully."`
6. Sets a `halted: true` flag on the subagent's Server state
7. After the ToolResult is sent back to the LLM and the response arrives, `run_agent_loop` checks `state.halted` and returns immediately

If the parent lookup fails (parent died permanently), the result is emitted via telemetry and the subagent halts.

`report_status` is a no-op for v1 — returns an acknowledgment but doesn't notify the parent.

### Subagent Shutdown

After `report_result` sets `halted: true` and the current turn completes:

1. The subagent's `handle_info({:mailbox_flush, ...})` checks `state.halted` before calling `run_agent_loop` — if halted, it's a no-op
2. The parent demonitors the subagent Server pid when it receives `{:subagent_result, ...}`
3. The subagent remains alive but inert — it could be stopped explicitly by the parent via `SkillKit.stop_agent(agent_ref)` or left to be cleaned up when the parent stops

### Resume Message

When the parent receives `{:subagent_result, pid, result}`, it builds a rich System message:

```
[Subagent Complete] <name> finished the task you delegated.

**Your plan before delegating:** "<parent_intent>"
**Task you delegated:** "<task>"
**Result:**
<result>

Continue with your plan.
```

This replaces the current bare message format. The existing `handle_info(:subagent_result)` is updated — `entry.task_ref` references are replaced with `entry.task` and `entry.parent_intent`. The parent demonitors after receiving the result. The message is injected into the mailbox, triggering a new parent turn with full context.

### Depth Limiting

The `Definition` already has `max_agent_depth`. The Server checks `state.depth < state.definition.max_agent_depth` before spawning. If at max depth, returns a ToolResult error: `"Cannot spawn subagent: max depth reached."`.

### Subagent Tool Availability

The ToolBuilder already handles this: when `subagent: true` is passed, it includes `report_status` and `report_result` builtins. The Server passes `subagent: state.depth > 0` to `ToolBuilder.build_tools/2` so subagents get the builtins and top-level agents don't. Subagents also see other agent definitions as tools, but depth limiting prevents infinite recursion.

### Changes to execute_tool_calls

The `:builtin` branch currently calls `builtin_placeholder(tc)` which only receives the ToolCall. This changes to `handle_builtin(tc, acc)` which receives state, matching the pattern of `:handler` and `:activate_skill`.

### Finding the Definition

The Server finds the subagent's `%Definition{}` by name from `state.kits`:

```elixir
definition = state.kits
|> Enum.flat_map(& &1.agents)
|> Enum.find(& &1.name == tool_call.name)
```

If not found, return a ToolResult error.

### State Changes

**Server struct additions:**
- `halted: false` — set to true after `report_result`
- `parent_registry: atom() | nil` — the parent's Registry name (for `report_result` lookup)

**Server opts additions:**
- `:parent_registry` — passed through from spawn_subagent via Agent opts

**Agent opts additions:**
- `:parent_registry` — optional, forwarded to Server

## Scope

### In scope
- Replace `subagent_placeholder` with real `spawn_subagent` using `SkillKit.start_agent/2`
- Implement `report_result` builtin (sends result to parent, halts subagent)
- Implement `report_status` as a no-op acknowledgment
- Rich resume message with parent_intent + task + result
- Depth limiting
- Independent subagent lifecycle (not tied to parent)
- Parent Registry name passed to subagent for result delivery
- Unique subagent naming
- Monitor subagent Server pid
- Pass `subagent: true` flag to ToolBuilder for child agents
- Demo: code-reviewer subagent AGENT.md + updated parent system prompt

### Out of scope
- Subagent timeout/cancellation
- Parallel subagent coordination
- Subagent-to-subagent communication
- `report_status` forwarding to parent
- Conversation state persistence / parent restart recovery
- SubagentSupervisor usage (remains unused in v1)

## Testing Strategy

- **Unit**: `spawn_subagent` starts independent agent via `SkillKit.start_agent`, returns immediate ToolResult, stores entry keyed by Server pid
- **Unit**: `report_result` looks up parent via parent_registry, sends result from Server pid, sets halted flag
- **Unit**: `report_result` when parent is gone — emits telemetry, halts gracefully
- **Unit**: `handle_info(:subagent_result)` builds resume message with parent_intent/task/result, demonitors
- **Unit**: Depth limit check prevents spawning when at max depth
- **Unit**: Definition lookup from kits finds matching agent, returns error for unknown
- **Unit**: Halted subagent ignores further mailbox flushes
- **Unit**: Parent receives both `:subagent_result` and `:DOWN` — result is processed, DOWN is ignored (pid already removed from map)
- **Integration**: Parent delegates to subagent, subagent uses bash + report_result, parent receives result and continues
