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
├── Agent.Registry (Registry)                        ← name lookup, keyed by {owner_pid, agent_name}
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

`Agent.SubagentSupervisor` is the team. Siblings under the same supervisor are peers — they share an owner and can address each other via the registry using `{owner_pid, agent_name}` as the key.

### Supervision strategies

**`Agent` → `:rest_for_one`**
Components are ordered: Mailbox, Server, SubagentSupervisor. If Mailbox crashes, everything restarts — an agent without its mailbox would silently lose messages. If Server crashes, SubagentSupervisor restarts too — orphaned subagents with no parent to report to should not continue running. This applies equally to primary agents and subagent-agents.

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
    :name,
    :owner_pid,        # nil for primary agents, parent Agent.Server pid for subagent-agents
    :definition,
    :depth,            # 0 = primary agent, increments with each agent spawn
    subagents: %{},    # pid → %{task, monitor_ref, restart, attempts}
    results: %{},      # task_id → result
    pending_requests: %{}   # correlation_id → %{payload, on_reply}
  ]

  # Spawn a skill subagent — no depth restriction
  defp spawn_subagent(state, task, :skill) do
    do_spawn_skill(state, task)
  end

  # Spawn an agent subagent — guarded by depth
  defp spawn_subagent(%{depth: depth, definition: %{max_agent_depth: max}} = state, task, :agent)
    when depth < max do
    do_spawn_agent(state, task, depth + 1)
  end

  defp spawn_subagent(%{depth: depth, definition: %{max_agent_depth: max}}, _task, :agent)
    when depth >= max do
    {:error, :max_agent_depth_exceeded}
  end

  # Incoming message batch from mailbox — user requests or peer messages
  def handle_info({:mailbox_flush, messages}, state) do
    {replies, messages} = Enum.split_with(messages, fn m ->
      not is_nil(m.correlation_id) and Map.has_key?(state.pending_requests, m.correlation_id)
    end)

    state = Enum.reduce(replies, state, fn reply, state ->
      {entry, pending} = Map.pop(state.pending_requests, reply.correlation_id)
      entry.on_reply.(reply.payload)
      %{state | pending_requests: pending}
    end)

    {:noreply, run_agent_loop(state, messages)}
  end

  # Subagent finished normally
  def handle_info({:subagent_result, pid, result}, state) do
    {entry, subagents} = Map.pop(state.subagents, pid)
    state = %{state |
      subagents: subagents,
      results: Map.put(state.results, entry.task_id, {:ok, result})
    }
    {:noreply, maybe_continue(state)}
  end

  # Subagent process died
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_by_monitor(state.subagents, ref) do
      nil          -> {:noreply, state}
      {pid, entry} -> {:noreply, handle_subagent_down(state, pid, entry, reason)}
    end
  end
end
```

### `Agent.Mailbox`

Buffers incoming messages and flushes to `Agent.Server` after either a size threshold or interval — whichever comes first.

```elixir
defmodule Agent.Mailbox do
  use GenServer

  defstruct [
    :agent_pid,
    :max_messages,
    :flush_interval,
    :timer_ref,
    messages: []
  ]

  def init({agent_pid, config}) do
    state = %__MODULE__{
      agent_pid:      agent_pid,
      max_messages:   config.max_messages,
      flush_interval: config.flush_interval,
      timer_ref:      schedule_flush(config.flush_interval)
    }
    {:ok, state}
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
    send(state.agent_pid, {:mailbox_flush, Enum.reverse(state.messages)})
    %{state | messages: [], timer_ref: schedule_flush(state.flush_interval)}
  end

  defp schedule_flush(interval), do: Process.send_after(self(), :flush, interval)
  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
```

### `Subagent.Skill`

Ephemeral. Spawned under `Agent.SubagentSupervisor`. Activates the skill via `Catalog`, renders the body for LLM context, and executes commands through the `Execution` pipeline.

```elixir
defmodule Subagent.Skill do
  use GenServer

  def init({parent, task_id, registry, skill_name, args, scopes}) do
    send(self(), :run)
    {:ok, %{parent: parent, task_id: task_id, registry: registry,
            skill_name: skill_name, args: args, scopes: scopes}}
  end

  def handle_info(:run, state) do
    with {:ok, rendered_body} <- SkillKit.Catalog.activate(
           state.registry, state.skill_name, state.args, scopes: state.scopes
         ),
         {:ok, skill} <- SkillKit.Catalog.get_skill(
           state.registry, state.skill_name, scopes: state.scopes
         ) do
      # rendered_body goes to LLM context; LLM returns a command to execute
      command = get_command_from_llm(rendered_body)
      context = build_context(state, skill)
      result = SkillKit.Executor.run(state.registry, skill, command, context)
      send(state.parent, {:subagent_result, self(), result})
    else
      error -> send(state.parent, {:subagent_result, self(), error})
    end

    {:stop, :normal, state}
  end

  defp build_context(state, skill) do
    %{
      cwd: skill.location && Path.dirname(skill.location),
      scope: state.scopes
    }
  end
end
```

### `Subagent.Agent`

Ephemeral. Wraps a full `Agent` supervision tree but with the same external interface as `Subagent.Skill` — reports a result to parent and stops.

---

## Messaging

Agents address siblings by name via the registry. The registry key is `{owner_pid, agent_name}` — siblings share the same `owner_pid` (the parent `Agent.Server` that spawned them), so names are naturally scoped without a separate team ID. All messaging is fire-and-forget — no blocking calls between agents. When a reply is needed, the sender tags the message with a correlation ID and matches on it when the reply arrives via the next mailbox flush.

```elixir
defmodule Agent.Messaging do

  # Fire and forget — no reply expected
  def send_message(owner_pid, agent_name, payload, from_mailbox) do
    message = %{correlation_id: nil, from_mailbox: from_mailbox, payload: payload}
    dispatch(owner_pid, agent_name, message)
  end

  # Fire and track — reply expected, returns correlation_id for matching
  def request(owner_pid, agent_name, payload, from_mailbox) do
    correlation_id = make_ref()
    message = %{correlation_id: correlation_id, from_mailbox: from_mailbox, payload: payload}
    case dispatch(owner_pid, agent_name, message) do
      :ok   -> {:ok, correlation_id}
      error -> error
    end
  end

  # Reply to a received message — routes through sender's mailbox
  def reply(%{correlation_id: id, from_mailbox: mailbox}, payload) when not is_nil(id) do
    message = %{correlation_id: id, from_mailbox: mailbox, payload: payload}
    GenServer.cast(mailbox, {:message, message})
  end

  defp dispatch(owner_pid, agent_name, message) do
    case Registry.lookup(Agent.Registry, {owner_pid, agent_name}) do
      [{pid, _}] -> GenServer.cast(pid, {:message, message}); :ok
      []         -> {:error, :not_found}
    end
  end
end
```

The sending agent tracks pending requests in its state and matches on correlation IDs when the mailbox flushes:

```elixir
# Sending a request to a sibling and registering a callback
def request_from_sibling(state, agent_name, payload, on_reply) do
  {:ok, correlation_id} = Agent.Messaging.request(state.owner_pid, agent_name, payload, state.mailbox_pid)
  pending = Map.put(state.pending_requests, correlation_id, %{
    payload:  payload,
    on_reply: on_reply
  })
  %{state | pending_requests: pending}
end

# On mailbox flush — split replies from new messages, resolve pending requests
def handle_info({:mailbox_flush, messages}, state) do
  {replies, messages} = Enum.split_with(messages, fn m ->
    not is_nil(m.correlation_id) and Map.has_key?(state.pending_requests, m.correlation_id)
  end)

  state = Enum.reduce(replies, state, fn reply, state ->
    {entry, pending} = Map.pop(state.pending_requests, reply.correlation_id)
    entry.on_reply.(reply.payload)
    %{state | pending_requests: pending}
  end)

  {:noreply, run_agent_loop(state, messages)}
end
```

All messages to an agent go through its mailbox process, not directly to `Agent.Server`.

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
        DynamicSupervisor.start_child(
          subagent_supervisor(agent_server),
          {Subagent.Skill, {agent_server, task_id, registry, skill_name, args, scopes}}
        )
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

Each agent's registry is initialized at startup with workspace-scoped skill directories:

```elixir
# In Agent supervisor init — registry is a child before Server
skill_dirs = [
  "#{definition.workspace}/skills",
  "#{definition.workspace}/.claude/skills",
  Path.expand("~/.agents/skills")               # shared fallback
]

children = [
  {SkillKit.Registry, name: registry_name, skill_dirs: skill_dirs},
  {Agent.Mailbox, {self(), definition.mailbox}},
  {Agent.Server, {definition, registry_name, depth}},
  {DynamicSupervisor, name: subagent_supervisor_name}
]
```

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
