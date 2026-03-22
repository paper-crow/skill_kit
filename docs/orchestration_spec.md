# Agent Orchestration Spec

## Overview

The orchestration layer manages the lifecycle of agent teams, agents, and subagents. It follows the Claude Code and Agent Skills specs for file formats and behavioral conventions, and maps those concepts onto OTP primitives for process management, supervision, and messaging.

---

## Concepts

### Agent
There is one kind of agent. All agents have the same structure: a mailbox, a server driving the LLM loop, and a dynamic supervisor for subagents. What differs is position in the tree and where messages come from.

**Primary agent** — started by the application, one per session or tenant. Its upstream is the user. It receives user requests through its mailbox, decides when to delegate, spawns subagents for parallel work, and reports results back to the user. In the Claude case, Claude itself is the primary agent.

**Subagent-agent** — spawned by a parent agent when work requires its own agentic loop. Its upstream is the parent agent. Same structure, lives under the parent's `Agent.SubagentSupervisor`, stops when its task is complete.

Agents are defined by `AGENT.md` files following the Claude Code subagent format.

### Subagent
An ephemeral process spawned by an agent to do a unit of work. A subagent is either:
- **Skill** — runs a `SKILL.md` via the executor, returns a result, stops
- **Agent** — runs its own agentic loop, can spawn its own subagents, returns a final result, stops

Both types live under the parent's `Agent.SubagentSupervisor` — which is the team. Both share the same interface from the parent's perspective: receive a task, return a result, stop.

### Workspace
Each agent owns a workspace — a directory that defines its scope of responsibility. Skills are discovered relative to the agent's workspace, so two agents can have skills with the same name without conflict. A shared global skills path acts as a fallback for skills available to all agents.

```
~/.agents/
├── main/                        # primary agent
│   ├── AGENT.md                 # role: general assistant, routes to project agents
│   └── skills/                  # main agent's skills
└── project-a/                   # project agent
    ├── AGENT.md                 # role: project A manager
    ├── SOUL.md                  # behavioral norms, responsibilities, reporting chain
    └── skills/                  # project-specific skills
        ├── build/
        │   └── SKILL.md
        └── deploy/
            └── SKILL.md

~/.agents/skills/                # shared skills available to all agents
```

The primary agent's catalog includes available agents discovered from workspace paths. When a user asks about project A, the primary agent matches it to the `project-a` agent definition and spawns it as a subagent-agent. The project agent handles the work within its own workspace and reports results back.

---

## File Formats

### `AGENT.md`

Follows the Claude Code subagent format with Elixir-specific mailbox configuration added via `metadata`.

```markdown
---
name: project-a
description: Manages project A. Use when the user asks about project A, its build, deployment, or codebase.
tools: Read, Grep, Glob, Bash
model: claude-sonnet-4-6
metadata:
  workspace: ~/.agents/project-a
  max_agent_depth: "1"
  mailbox_max_messages: "5"
  mailbox_flush_interval: "200"
---

You are the project A manager. You own the project A codebase and are responsible
for builds, deployments, and code quality. Report results clearly back to the main agent.
```

Required frontmatter fields follow the Agent Skills spec:

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Lowercase, hyphens only, max 64 chars |
| `description` | Yes | When to use this agent, max 1024 chars |
| `tools` | No | Space-delimited allowed tools |
| `model` | No | Model override, inherits from team if omitted |
| `metadata.workspace` | No | Root path for this agent's skills, memory, and files |
| `metadata.max_agent_depth` | No | Max depth agents can spawn agents (default: 1, matches Claude spec) |
| `metadata.mailbox_max_messages` | No | Flush after N messages (default: 10) |
| `metadata.mailbox_flush_interval` | No | Flush after N ms (default: 500) |

The markdown body becomes the agent's system prompt.

### Discovery paths

Following the Agent Skills spec scan convention:

```
<project>/.claude/agents/     # project-scoped agents
~/.claude/agents/             # user-scoped agents
<project>/.agents/agents/     # cross-client interoperability
```

Project-scoped agents override user-scoped agents of the same name.

---

## Supervision Tree

```
Application
├── Agent.Registry (Registry)                        ← name lookup for all agent components
└── Agent.Supervisor (DynamicSupervisor)             ← owns primary agents
    └── Agent (Supervisor, :rest_for_one)            ← one per session/tenant
        ├── Agent.Mailbox (GenServer)                ← buffers user requests + peer messages
        ├── Agent.Server (GenServer)                 ← state, LLM loop
        └── Agent.SubagentSupervisor (DynamicSupervisor)  ← the "team"
            ├── Subagent.Skill (GenServer)           ← ephemeral, runs executor
            └── Subagent.Agent (Supervisor)          ← ephemeral, full agent tree
                ├── Agent.Mailbox
                ├── Agent.Server
                └── Agent.SubagentSupervisor         ← depth-limited agent spawning
                    └── ...
```

`Agent.SubagentSupervisor` is the team. Siblings under the same supervisor are peers — they share an owner and can address each other via the registry.

### Process discovery via Registry

Agent components find each other through `Agent.Registry` rather than passing pids at init. Each process registers under `{agent_name, role}` where role is `:mailbox`, `:server`, or `:subagent_supervisor`:

```elixir
# Each process registers itself in init
Registry.register(Agent.Registry, {agent_name, :mailbox}, [])
Registry.register(Agent.Registry, {agent_name, :server}, [])
Registry.register(Agent.Registry, {agent_name, :subagent_supervisor}, [])

# Lookup siblings by name
defp lookup(agent_name, role) do
  case Registry.lookup(Agent.Registry, {agent_name, role}) do
    [{pid, _}] -> {:ok, pid}
    [] -> {:error, :not_found}
  end
end
```

This solves the `:rest_for_one` startup ordering problem — Mailbox starts before Server, but doesn't need Server's pid at init. When Mailbox flushes, it looks up `{agent_name, :server}` in the registry. Server does the same for `{agent_name, :mailbox}` and `{agent_name, :subagent_supervisor}`.

All processes receive `agent_name` at init. That's the only coordination point — no pid wiring, no post-init handshakes.

### Supervision strategies

**`Agent` → `:rest_for_one`**
Components are ordered: Mailbox, Server, SubagentSupervisor. If Mailbox crashes, everything restarts — an agent without its mailbox would silently lose messages. If Server crashes, SubagentSupervisor restarts too — orphaned subagents with no parent to report to should not continue running. This applies equally to primary agents and subagent-agents.

When a process restarts, it re-registers in `Agent.Registry` under the same `{agent_name, role}` key. The OTP `Registry` automatically unregisters crashed processes, so the new instance claims the key cleanly.

### Application startup

The application starts infrastructure and primary agents. Primary agents are defined by `AGENT.md` files, same as any other agent.

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    primary_agents = Agent.Discovery.load_primary_agents()

    children = [
      {Registry, keys: :unique, name: Agent.Registry},
      {DynamicSupervisor, name: Agent.Supervisor, strategy: :one_for_one}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

    Enum.each(primary_agents, fn definition ->
      DynamicSupervisor.start_child(Agent.Supervisor, {Agent, {definition, depth: 0}})
    end)

    {:ok, sup}
  end
end
```

In a multi-tenant application, primary agents are started and stopped dynamically as sessions begin and end:

```elixir
# New tenant session
DynamicSupervisor.start_child(Agent.Supervisor, {Agent, {tenant_definition, depth: 0}})

# Session ends
DynamicSupervisor.terminate_child(Agent.Supervisor, agent_pid)
```

---

## Agent Definition

```elixir
defmodule Agent.Definition do
  defstruct [
    :name,
    :description,
    :tools,
    :model,
    :system_prompt,
    :path,
    :workspace,
    max_agent_depth: 1,    # default matches Claude spec — only primary agent spawns agents
    mailbox: %{
      max_messages: 10,
      flush_interval: 500
    }
  ]

  def parse(path) do
    {frontmatter, body} = parse_markdown(path)
    metadata = frontmatter["metadata"] || %{}

    # workspace defaults to the directory containing AGENT.md
    workspace = metadata["workspace"] || Path.dirname(path)

    %__MODULE__{
      name:            frontmatter["name"],
      description:     frontmatter["description"],
      tools:           frontmatter["tools"],
      model:           frontmatter["model"],
      system_prompt:   body,
      path:            path,
      workspace:       Path.expand(workspace),
      max_agent_depth: parse_int(metadata["max_agent_depth"], 1),
      mailbox: %{
        max_messages:   parse_int(metadata["mailbox_max_messages"], 10),
        flush_interval: parse_int(metadata["mailbox_flush_interval"], 500)
      }
    }
  end
end
```

---

## Processes

### `Agent.Server`

The core agent process. Same structure whether it is a primary agent or a subagent-agent. Primary agents receive user requests through their mailbox. Subagent-agents receive tasks from their parent. Both process batched messages, drive the LLM loop, and manage their own subagents.

```elixir
defmodule Agent.Server do
  use GenServer

  defstruct [
    :agent_name,       # registry key — used to look up mailbox, supervisor, peers
    :parent_name,      # nil for primary agents, parent's agent_name for subagent-agents
    :definition,
    :depth,            # 0 = primary agent, increments with each agent spawn
    messages: [],      # conversation history — the full message list sent to the LLM
    subagents: %{},    # pid → %{task_ref, name, monitor_ref, restart, attempts}
    pending_requests: %{}   # correlation_id → %{payload, on_reply}
  ]

  def init({agent_name, definition, depth, parent_name}) do
    Registry.register(Agent.Registry, {agent_name, :server}, [])
    {:ok, %__MODULE__{
      agent_name: agent_name,
      parent_name: parent_name,
      definition: definition,
      depth: depth
    }}
  end

  # Look up sibling processes by role
  defp mailbox(state), do: whereis(state.agent_name, :mailbox)
  defp subagent_sup(state), do: whereis(state.agent_name, :subagent_supervisor)

  defp whereis(agent_name, role) do
    [{pid, _}] = Registry.lookup(Agent.Registry, {agent_name, role})
    pid
  end
end
```

### The Agent Loop

The agent loop runs synchronously within `handle_info`. While the loop is active the GenServer is blocked — incoming messages (user, peer, subagent results) buffer in the mailbox and are processed on the next turn. This is by design: an agent that is "thinking" should not be interrupted mid-turn.

To the LLM, everything is a tool — local executors, skill subagents, and agent subagents are all presented as tools. The orchestration layer routes each tool call to the right execution path.

```
handle_info({:mailbox_flush, messages}, state)
  1. Append new messages to state.messages
  2. Stream LLM (state.messages, llm_opts)
  3. Append assistant response to state.messages
  4. Classify tool calls:
     - Local tool calls → execute immediately, collect tool_results
     - Subagent tool calls → spawn subagent, return placeholder tool_result:
         "Delegated to agent '{name}'. Task ref: {ref}.
          You will receive the result as a message."
  5. Append all tool_results to state.messages
  6. If any tool calls were made → goto 2 (LLM sees results, continues)
  7. No tool calls → turn complete, return updated state
```

**Subagent results arrive as messages, not tool results.** The delegation tool call is already resolved (with the placeholder). When the subagent finishes, its result enters the conversation as a new message:

```
"[Background task {ref} complete] Agent '{name}' returned: {result}"
```

This arrives through the mailbox like any other message, triggers a new turn through the loop, and the LLM incorporates it alongside any user messages that arrived in the meantime. The task ref lets the LLM correlate the result with the original delegation.

The agent's system prompt instructs it how to handle these: proactively inform the user when background work completes.

```elixir
  # Incoming message batch from mailbox — user requests, peer messages, or subagent results
  def handle_info({:mailbox_flush, messages}, state) do
    {replies, new_messages} = Enum.split_with(messages, fn m ->
      not is_nil(m.correlation_id) and Map.has_key?(state.pending_requests, m.correlation_id)
    end)

    state = Enum.reduce(replies, state, fn reply, state ->
      {entry, pending} = Map.pop(state.pending_requests, reply.correlation_id)
      entry.on_reply.(reply.payload)
      %{state | pending_requests: pending}
    end)

    {:noreply, run_agent_loop(state, new_messages)}
  end

  # Subagent finished — inject result as a conversation message via the mailbox
  def handle_info({:subagent_result, pid, result}, state) do
    {entry, subagents} = Map.pop(state.subagents, pid)
    state = %{state | subagents: subagents}

    message = %{
      role: "user",
      content: "[Background task #{entry.task_ref} complete] " <>
               "Agent '#{entry.name}' returned: #{inspect(result)}"
    }

    GenServer.cast(mailbox(state), {:message, wrap_message(message)})
    {:noreply, state}
  end

  # Subagent process died — inject error as a conversation message
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case pop_by_monitor(state.subagents, ref) do
      nil ->
        {:noreply, state}

      {entry, subagents} ->
        state = %{state | subagents: subagents}

        message = %{
          role: "user",
          content: "[Background task #{entry.task_ref} failed] " <>
                   "Agent '#{entry.name}' crashed: #{inspect(reason)}"
        }

        GenServer.cast(mailbox(state), {:message, wrap_message(message)})
        {:noreply, maybe_restart(state, entry, reason)}
    end
  end

  # The core loop — called from handle_info, runs synchronously
  defp run_agent_loop(state, new_messages) do
    state = append_messages(state, new_messages)
    {:ok, stream} = SkillKit.LLM.stream(state.messages, state.definition.llm_opts)
    response = collect_response(stream)
    state = append_assistant(state, response)

    case classify_tool_calls(response) do
      [] ->
        # No tool calls — turn complete
        deliver_response(state, response)
        state

      tool_calls ->
        {local, subagent} = Enum.split_with(tool_calls, &local?/1)

        # Execute local tools immediately
        local_results = Enum.map(local, &execute_local(state, &1))

        # Spawn subagents, get placeholder results
        {subagent_results, state} = Enum.map_reduce(subagent, state, &spawn_and_acknowledge/2)

        # Append all tool results and loop
        all_results = local_results ++ subagent_results
        state = append_tool_results(state, all_results)
        run_agent_loop(state, [])
    end
  end

  # Spawn a subagent — guarded by depth for agent subagents
  defp spawn_and_acknowledge(tool_call, state) do
    task_ref = make_ref()

    # ... spawn under SubagentSupervisor, monitor, track in state.subagents ...

    placeholder = %{
      tool_call_id: tool_call.id,
      content: "Delegated to agent '#{tool_call.name}'. Task ref: #{inspect(task_ref)}. " <>
               "You will receive the result as a message."
    }

    {placeholder, state}
  end
end
```

### Why this works

- **No blocked turns.** Local tool calls resolve immediately. Subagent calls return a placeholder and the LLM continues — it can respond to the user ("I've kicked off that analysis...") while the subagent runs.
- **No special pending state.** There's no `pending_tool_calls` map to reassemble. Each tool call gets a result in the same turn. Subagent results are new messages, not retroactive tool results.
- **Natural conversation flow.** The user can send messages while a subagent runs. When the result arrives, the LLM sees both the result and any user messages that came in, and responds with full context.
- **Crash handling is just messaging.** A crashed subagent produces an error message in the conversation. The LLM decides what to do — retry, report, move on. No special error recovery machinery in the orchestration layer.

### `Agent.Mailbox`

Buffers incoming messages and flushes to `Agent.Server` after either a size threshold or interval — whichever comes first.

```elixir
defmodule Agent.Mailbox do
  use GenServer

  defstruct [
    :agent_name,
    :max_messages,
    :flush_interval,
    :timer_ref,
    messages: []
  ]

  def init({agent_name, config}) do
    Registry.register(Agent.Registry, {agent_name, :mailbox}, [])
    {:ok, %__MODULE__{
      agent_name:     agent_name,
      max_messages:   config.max_messages,
      flush_interval: config.flush_interval,
      timer_ref:      schedule_flush(config.flush_interval)
    }}
  end

  def handle_cast({:message, message}, state) do
    messages = [message | state.messages]
    state = %{state | messages: messages}

    if length(messages) >= state.max_messages do
      {:noreply, flush(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:flush, state) do
    {:noreply, flush(state)}
  end

  defp flush(%{messages: []} = state) do
    %{state | timer_ref: schedule_flush(state.flush_interval)}
  end
  defp flush(state) do
    cancel_timer(state.timer_ref)
    server = whereis(state.agent_name, :server)
    send(server, {:mailbox_flush, Enum.reverse(state.messages)})
    %{state | messages: [], timer_ref: schedule_flush(state.flush_interval)}
  end

  defp whereis(agent_name, role) do
    [{pid, _}] = Registry.lookup(Agent.Registry, {agent_name, role})
    pid
  end

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
```

### `Subagent.Skill`

Ephemeral. Spawned under `Agent.SubagentSupervisor`. Activates the skill via `Catalog`, renders the body for LLM context, streams through the LLM backend to produce a command, and executes through the `Execution` pipeline.

```elixir
defmodule Subagent.Skill do
  use GenServer

  defstruct [
    :parent,
    :task_id,
    :registry,
    :skill_name,
    :args,
    :scopes,
    :llm_opts
  ]

  def start_link(%__MODULE__{} = task) do
    GenServer.start_link(__MODULE__, task)
  end

  def init(%__MODULE__{} = task) do
    send(self(), :run)
    {:ok, task}
  end

  def handle_info(:run, task) do
    with {:ok, rendered_body} <- SkillKit.Catalog.activate(
           task.registry, task.skill_name, task.args, scopes: task.scopes
         ),
         {:ok, skill} <- SkillKit.Catalog.get_skill(
           task.registry, task.skill_name, scopes: task.scopes
         ),
         {:ok, command} <- get_command(rendered_body, task.llm_opts) do
      context = build_context(task, skill)
      result = SkillKit.Executor.run(task.registry, skill, command, context)
      send(task.parent, {:subagent_result, self(), result})
    else
      error -> send(task.parent, {:subagent_result, self(), error})
    end

    {:stop, :normal, task}
  end

  # Streams the rendered skill body through the LLM backend to produce
  # a command for the executor. The parent agent passes llm_opts (which
  # may include a :backend override from the agent definition or skill metadata).
  defp get_command(rendered_body, llm_opts) do
    messages = [%{"role" => "user", "content" => rendered_body}]

    with {:ok, stream} <- SkillKit.LLM.stream(messages, llm_opts) do
      command = stream |> Enum.to_list() |> extract_command()
      {:ok, command}
    end
  end

  defp build_context(task, skill) do
    %{
      cwd: skill.location && Path.dirname(skill.location),
      scope: task.scopes
    }
  end
end
```

### `Subagent.Agent`

Ephemeral. Wraps a full `Agent` supervision tree but with the same external interface as `Subagent.Skill` — reports a result to parent and stops.

---

## Messaging

Agents address each other by name via `Agent.Registry`. All messaging is fire-and-forget — no blocking calls between agents. When a reply is needed, the sender tags the message with a correlation ID and matches on it when the reply arrives via the next mailbox flush.

Messages always route through the target agent's mailbox — never directly to `Agent.Server`.

```elixir
defmodule Agent.Messaging do

  # Fire and forget — no reply expected
  def send_message(target_name, payload, from_name) do
    message = %{correlation_id: nil, from: from_name, payload: payload}
    dispatch(target_name, message)
  end

  # Fire and track — reply expected, returns correlation_id for matching
  def request(target_name, payload, from_name) do
    correlation_id = make_ref()
    message = %{correlation_id: correlation_id, from: from_name, payload: payload}
    case dispatch(target_name, message) do
      :ok   -> {:ok, correlation_id}
      error -> error
    end
  end

  # Reply to a received message — routes through sender's mailbox
  def reply(%{correlation_id: id, from: from_name}, payload) when not is_nil(id) do
    message = %{correlation_id: id, from: from_name, payload: payload}
    dispatch(from_name, message)
  end

  defp dispatch(agent_name, message) do
    case Registry.lookup(Agent.Registry, {agent_name, :mailbox}) do
      [{pid, _}] -> GenServer.cast(pid, {:message, message}); :ok
      []         -> {:error, :not_found}
    end
  end
end
```

The sending agent tracks pending requests in its state and matches on correlation IDs when the mailbox flushes:

```elixir
# Sending a request to a sibling and registering a callback
def request_from_sibling(state, target_name, payload, on_reply) do
  {:ok, correlation_id} = Agent.Messaging.request(target_name, payload, state.agent_name)
  pending = Map.put(state.pending_requests, correlation_id, %{
    payload:  payload,
    on_reply: on_reply
  })
  %{state | pending_requests: pending}
end
```

---

## Subagent Lifecycle

1. Parent agent decides to delegate work
2. Parent spawns subagent under `Agent.SubagentSupervisor`, passing task and `self()` as parent pid
3. Subagent runs work (skill via executor, or full agentic loop)
4. Subagent sends `{:subagent_result, self(), result}` to parent
5. Subagent stops normally
6. Parent receives result in `handle_info`, closes the loop, continues

If the subagent crashes instead of returning a result, the parent's monitor fires `{:DOWN, ref, :process, pid, reason}` and the parent applies the restart strategy from the task definition.

---

## Restart Strategy

Tracked per subagent task in `Agent.Server` state:

```elixir
%{
  pid => %{
    task_id:      uuid,
    task:         task,
    restart:      :transient,   # :temporary | :transient | :permanent
    attempts:     1,
    max_attempts: 3,
    monitor_ref:  ref
  }
}
```

| Strategy | Behavior |
|---|---|
| `:temporary` | Never restart. Crash is reported as error. |
| `:transient` | Restart on crash, not on clean exit. |
| `:permanent` | Always restart, even after clean exit. |

Skill subagents default to `:temporary` — stateless, safe to retry from scratch if needed but not automatically. Agent subagents default to `:transient` — restart on unexpected crash, not when work is complete.

When `max_attempts` is exceeded the task is marked as failed and the parent agent decides whether to escalate.

---

## Skill Launch from Orchestration Layer

The orchestration layer bridges agent workspaces to the SkillKit Catalog and Executor. Each agent owns a `SkillKit.Registry` instance loaded with skills from its workspace directories. Skill resolution, authorization, and execution all go through the existing SkillKit APIs — the orchestration layer does not reimplement discovery.

```elixir
defmodule Agent.SkillLauncher do

  def launch(agent_server, task_id, skill_name, args, scopes) do
    registry = Agent.Server.registry(agent_server)

    case SkillKit.Catalog.get_skill(registry, skill_name, scopes: scopes) do
      {:ok, _skill} ->
        task = %Subagent.Skill{
          parent: agent_server,
          task_id: task_id,
          registry: registry,
          skill_name: skill_name,
          args: args,
          scopes: scopes,
          llm_opts: Agent.Server.llm_opts(agent_server)
        }

        DynamicSupervisor.start_child(
          subagent_supervisor(agent_server),
          {Subagent.Skill, task}
        )
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

Each agent's registry is initialized at startup with workspace-scoped skill directories:

```elixir
# In Agent supervisor init — all children receive agent_name, discover each other via Registry.
# No dynamic atoms — all processes register under {agent_name, role} tuples.
defmodule Agent do
  use Supervisor

  def start_link({agent_name, definition, depth, parent_name}) do
    Supervisor.start_link(__MODULE__, {agent_name, definition, depth, parent_name})
  end

  def init({agent_name, definition, depth, parent_name}) do
    backends = [
      {SkillKit.Backend.Filesystem, dirs: [
        "#{definition.workspace}/skills",
        "#{definition.workspace}/.claude/skills",
        Path.expand("~/.agents/skills")               # shared fallback
      ]}
    ]

    children = [
      {SkillKit.Supervisor, name: {:via, Registry, {Agent.Registry, {agent_name, :skill_supervisor}}},
        registry_name: {:via, Registry, {Agent.Registry, {agent_name, :skill_registry}}},
        backends: backends},
      {Agent.Mailbox, {agent_name, definition.mailbox}},
      {Agent.Server, {agent_name, definition, depth, parent_name}},
      {Agent.SubagentSupervisor, agent_name}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
```

`Agent.SubagentSupervisor` is a thin wrapper around `DynamicSupervisor` that registers itself via the Registry:

```elixir
defmodule Agent.SubagentSupervisor do
  def start_link(agent_name) do
    DynamicSupervisor.start_link(
      strategy: :one_for_one,
      name: {:via, Registry, {Agent.Registry, {agent_name, :subagent_supervisor}}}
    )
  end
end
```

All processes are discovered via `Registry.lookup(Agent.Registry, {agent_name, role})`. No dynamic atoms anywhere — agent names are strings, roles are static atoms.

---

## Open Considerations

### Output size

No hard limit on subagent output. If a skill produces unbounded output it should write to a file and return the path.

### Parallel subagents

An agent can spawn multiple subagents concurrently. Results arrive independently via `handle_info`. The agent tracks all in-flight subagents in its state map and decides when enough results have arrived to continue.

### Session serialization

Explicit session serialization is not needed. `GenServer` already processes messages sequentially — the mailbox queue is the command queue. A batch flushed from `Agent.Mailbox` is processed in a single `handle_info` call, within which `run_agent_loop` handles messages sequentially. The only real tool conflict risk is two subagents writing to the same file concurrently. That is a skill design concern, not an orchestration one — skills that mutate shared state should not be run in parallel.

### Workspace isolation

Skill discovery is workspace-scoped so agents are naturally isolated. The shared `~/.agents/skills/` fallback is available to all agents. If two agents need the same skill with different behaviour, each workspace defines its own version and the shared fallback is never reached.
