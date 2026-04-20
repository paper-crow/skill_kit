# AGENTS.md — Building New SkillKit Functionality

This file governs the `lib/skill_kit/` subtree. Read it before proposing or
writing any change inside SkillKit's core library.

## The prime directive

**Build with skills and kits. Do not modify the framework.**

SkillKit is an extension platform. Almost every feature request — webhooks,
cron triggers, external integrations, new capabilities, domain workflows —
can be expressed as a skill, a kit, a tool, a hook, or a host-side adapter
that calls the public API.

Before you change anything under `lib/skill_kit/`:

1. Work through the **Decision Tree** below and pick the extension point.
2. Prototype the feature as a kit (`use SkillKit.Kit`) or a host-side
   adapter that composes the existing public API.
3. Only if that prototype is physically impossible, write a short
   **Framework Change Proposal** (template at the bottom) and stop for
   human review.

"I could add a field to `%Skill{}`" is not a reason to add a field to
`%Skill{}`. Use `metadata:` or build a kit.

## What the framework already gives you

| Seam | Behaviour / Struct | File |
|---|---|---|
| Start an agent | `SkillKit.start_agent/2` | `skill_kit.ex:87` |
| Send a message | `SkillKit.send_message/2` | `skill_kit.ex:180` |
| Send + block for reply | `SkillKit.send_message_sync/3` | `skill_kit.ex:235` |
| Resume a suspended tool | `SkillKit.respond/3` | `skill_kit.ex:205` |
| Stop an agent | `SkillKit.stop_agent/1` | `skill_kit.ex:255` |
| Skill data | `%SkillKit.Skill{}` | `skill.ex:47` |
| Agent data | `%SkillKit.Agent{}` | `agent/agent.ex:31` |
| Kit packaging + `use` macro | `SkillKit.Kit` / `Kit.Provider` | `kit.ex:54`, `kit/provider.ex` |
| Tool behaviour | `SkillKit.Tool` (3 callbacks) | `tool.ex:36` |
| Tool execution envelope | `%SkillKit.ToolExecution{}` | `tool_execution.ex:33` |
| Lifecycle hooks | `SkillKit.Hook` (16 event types) | `hook.ex:17` |
| Hook handlers | `Hooks.Command`, `Hooks.Http`, `Hooks.Handler` | `hooks/` |
| Catalog queries | `SkillKit.Catalog` | `catalog.ex` |
| Conversation persistence | `SkillKit.Conversation.Store` behaviour | `conversation/store.ex` |
| LLM providers | `SkillKit.LLM` + per-vendor adapters | `llm/` |
| Scope / authorization | `SkillKit.Scope` protocol, `Authorization` | `scope/`, `authorization.ex` |
| Runtime (agent spawning) | `SkillKit.Runtime.Local` (default) | `runtime/local.ex` |
| Per-agent registry | `agent.registry` atom on `AgentRef` | `agent_ref.ex` |
| Suspension routing | `{agent.name, :pending_tool, id}` registry key | `agent/tool_runner.ex:110` |
| Mailbox routing | `{agent.name, :mailbox}` registry key | `skill_kit.ex:184` |

Every one of these is a supported extension point. Reach for these first.

## Decision tree

Start at the top. Pick the first match.

### Q1. Does the feature inject new prompt instructions into the agent?
→ **Write a SKILL.md.** Put it in the host app's skills directory (loaded via
`Kit.Local`) or ship it in a kit. No framework changes.

Use template tokens (`$ARGUMENTS`, `$SKILL_DIR`, `$SESSION_ID`, `$SCOPE_VAR`,
`` !`cmd` ``) for dynamic content. See `skill.ex:60-106` for the full token
grammar and `guides/skill-format.md` for the frontmatter fields.

### Q2. Does the feature need to execute code when a skill runs?
→ **Build a kit module.** `use SkillKit.Kit` makes the module both a
`Kit.Provider` (loads skills from a co-located `skills/` directory at
compile time) and a `Tool` (executes them). Skills loaded by the kit have
their `:tool` field auto-patched to the kit module — see `kit.ex:77`.

Implement `execute/1`, optionally override `resume/3` and `definition/0`.
`SkillKit.Tools.Shell` (`tools/shell.ex`) is the canonical reference.

### Q3. Does the feature need to respond to external events (HTTP, cron, queue, pubsub)?
→ **Build a host-side adapter that calls `SkillKit.send_message/2`.** Do not
add an event ingress layer to SkillKit.

The adapter (a Plug, a `GenServer`, a `Task`, a Broadway pipeline) lives in
the host application or a companion package. It owns its own process tree.
When an event arrives, it resolves an `AgentRef` and dispatches. The agent
is the brain; the adapter is the nervous system.

**Worked example: webhook adapter (no framework changes).**

```elixir
# In the host app (or a companion package like skill_kit_web):

defmodule MyApp.WebhookPlug do
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{path_info: [id]} = conn, _opts) do
    case MyApp.WebhookRegistry.lookup(id) do
      {:ok, %{agent_name: name, registry: reg, prompt: prompt}} ->
        payload = read_payload(conn)
        rendered = render(prompt, payload)

        case Registry.lookup(reg, {name, :mailbox}) do
          [{pid, _}] ->
            GenServer.cast(pid, {:message, %SkillKit.Types.UserMessage{content: rendered}})
            send_resp(conn, 202, "")
          [] ->
            send_resp(conn, 503, "agent not running")
        end

      :error ->
        send_resp(conn, 404, "")
    end
  end
end
```

And a kit-side tool that registers on activation:

```elixir
defmodule MyApp.Skills.Webhooks do
  use SkillKit.Kit, name: "webhooks"

  @impl SkillKit.Tool
  def execute(%SkillKit.ToolExecution{input: input, context: ctx}) do
    id = MyApp.WebhookRegistry.register(%{
      agent_name: ctx.agent_name,
      registry:   ctx.registry,
      prompt:     input["prompt"]
    })
    {:ok, "Webhook URL: #{MyApp.WebhookRegistry.url_for(id)}"}
  end
end
```

Notes on this pattern:
- Registration is keyed by agent name. If the agent isn't running when a
  request arrives, the adapter returns 503. That is the contract.
- The kit does not touch `%Skill{}`, `%Agent{}`, `Catalog`, or any private
  internals. It only uses `ToolExecution.context` and the public registry
  atom in the `AgentRef`.
- Durability, if needed, belongs in the host-side registry (not in
  SkillKit).
- The `agent_name` and `registry` arrive through `context`. Populate
  context from the agent struct in your kit's `execute/1` wrapper or
  from the `%ToolExecution{}` passed in — they're already there via the
  agent's Server state.

### Q4. Does the feature gate an existing action (tool use, subagent, skill activation, conversation save, LLM request)?
→ **Declare a hook in a skill's frontmatter.** Do not hardcode new gate
points in `Agent.Server`.

Events available (`hook.ex:17`): `pre_tool_use`, `post_tool_use`,
`pre_subagent`, `post_subagent`, `pre_skill_activation`,
`post_skill_activation`, `pre_conversation_save`, `post_conversation_save`,
`pre_conversation_load`, `post_conversation_load`, `pre_llm_request`,
`post_llm_request`, `pre_turn`, `post_turn`, `pre_agent`, `post_agent`.

Hooks are **gate-only**: allow, deny, or suspend. They cannot transform
data. If you need transformation, you need a different mechanism; propose
it, don't silently add mutation to hooks.

### Q5. Does the feature need human-in-the-loop input mid-execution?
→ **Return `{:pending, state}` from `execute/1`.** The caller receives an
`%Event.InputRequested{}`. When they call `SkillKit.respond/3` with an
answer, your `resume/3` callback runs with that answer. See
`agent/tool_runner.ex:108-153` for the suspension lifecycle.

### Q6. Does the feature need custom skill storage (DB, remote API, dynamic source)?
→ **Implement `SkillKit.Kit.Provider`.** Three callbacks:
`load_kits/1`, `list_kits/1`, `get_kit/2`. Return `%Kit{}` structs
containing `%Skill{}` structs. `Kit.Local`, `Kit.Memory`, and `Kit.GitHub`
are existing reference implementations in `kit/`.

### Q7. Does the feature need a new LLM vendor?
→ **Implement the LLM adapter behaviour** in `llm/`. Register via
`config :skill_kit, SkillKit.LLM, providers: [...]`.

### Q8. Does the feature need custom conversation persistence?
→ **Implement `SkillKit.Conversation.Store`.** Pass the module as the
`:conversation_store` option to `start_agent/2`.

### Q9. Does the feature need scope variable resolution (e.g. `$TENANT` in skill bodies)?
→ **Implement the `SkillKit.Scope` protocol** on your scope struct. The
renderer calls `Scope.resolve/3` for any `$VAR` left after built-in token
substitution (`skill.ex:165`).

### Q10. Does the feature need to spawn agents somewhere other than the local BEAM?
→ **Implement a custom runtime** modeled on `SkillKit.Runtime.Local`.
Distribute via the `:runtime` option on `start_agent/2`.

### Q11. None of the above fits.
→ Go to **Framework Change Proposal** below. Stop before editing.

## What must not change without explicit approval

These are the load-bearing invariants of SkillKit. Do not modify them
without a written proposal and approval:

- **`%Skill{}` struct shape** (`skill.ex:47`). Use `metadata:` for custom
  fields. If you find yourself wanting `skill.webhook_url`, you are
  building the feature in the wrong layer.
- **`%Agent{}` struct shape** (`agent/agent.ex:31`). Same rule: use
  `metadata` in the agent's frontmatter.
- **The 16 hook events** (`hook.ex:17`). Adding an event type means adding
  a dispatch site in `Agent.Server` — a real design decision.
- **The Tool callback contract** (`tool.ex:36`). `{:ok | :error | :pending}`
  is the universal return shape. Do not add a fourth variant.
- **The supervision tree** (`agent/supervisor.ex`, `agent/core.ex`).
  `one_for_one` at the top, `rest_for_one` inside Core, three children
  each. Mailbox → Server → ToolRunner ordering matters.
- **Registry key conventions**: `{agent.name, :mailbox}`,
  `{agent.name, :catalog}`, `{agent.name, :pending_tool, id}`,
  `{agent.name, :tool_runner}`. Adapters that need to look up agent
  components must use these keys; do not invent new ones inside the
  framework.
- **The public API surface of `SkillKit`** (`skill_kit.ex`). Adding
  functions here is a design decision, not a fix.

## When a framework change is genuinely justified

After walking the decision tree, if none of Q1–Q10 can express the
feature, write a proposal (≤ 200 words) covering:

1. **What you tried.** Which extension points you ruled out and why.
   Name the specific callback or struct field that fell short.
2. **The minimal change.** The smallest diff that unblocks the feature.
   Identify the exact module and function — not "rework the Catalog",
   but "add `Catalog.list_webhooks/1` mirroring `list_hooks/1` at
   `catalog.ex:141`".
3. **Why this seam.** Why is the seam you chose the right one vs.
   alternatives? What's the blast radius on existing skills and kits?
4. **Compatibility.** What existing tests or public contracts would
   need to move?

Do not write the code alongside the proposal. Stop and wait for review.

## Testing your addition

- `mix precommit` — full validation pipeline (compile with warnings-as-
  errors, format, credo --strict, test). Run this before declaring work
  complete. See `CLAUDE.md` at the repo root.
- `mix test path/to/file_test.exs:42` — run one test.
- Test config uses the `:mock` LLM provider (`config/test.exs`) — you do
  not need a live API key to write tests.
- For skill-level tests: drop fixtures under `test/support/fixtures/`
  and load them via `Kit.Local`. Look at the existing tests under
  `test/skill_kit/` for patterns.
- For tool-level tests: build a `%ToolExecution{}` directly and call
  `execute/1`. No agent process required.
- For integration tests: use `SkillKit.start_agent/2` with
  `caller: self()` and assert on the events your process receives.

## Code style (inherited from CLAUDE.md at repo root)

- No alias shortcuts. Alias each module individually.
- Never pipe into a single function or into `case`/`if`/`with`.
- Never inline multiline expressions inside `case`/`with`/`if` clauses —
  extract a private helper.
- Prefer `&` capture over `fn` for simple expressions.
- Use recursive function heads for data normalization.
- Conventional commits: `type(scope): message`.

## Quick reference: where things live

```
lib/skill_kit/
├── skill.ex                   # %Skill{} + render/4
├── kit.ex                     # %Kit{} + `use SkillKit.Kit` macro
├── tool.ex                    # Tool behaviour (3 callbacks)
├── tool_execution.ex          # %ToolExecution{} + execute/1, resume/2
├── hook.ex                    # %Hook{} + 16 events
├── hooks.ex                   # dispatch
├── catalog.ex                 # per-agent GenServer
├── frontmatter.ex             # YAML + body parser
├── agent/
│   ├── agent.ex              # %Agent{} + AGENT.md parser
│   ├── supervisor.ex         # Registry + Catalog + Core
│   ├── core.ex               # Mailbox + Server + ToolRunner
│   ├── mailbox.ex            # user message buffering
│   ├── server.ex             # LLM loop
│   ├── tool_dispatch.ex      # per-call invocation
│   └── tool_runner.ex        # batch runner + suspension
├── kit/
│   ├── provider.ex           # Kit.Provider behaviour
│   ├── local.ex              # filesystem provider
│   ├── memory.ex             # in-memory provider
│   └── github.ex             # GitHub provider
├── tools/
│   └── shell.ex              # canonical Tool + Kit reference
├── hooks/                    # built-in handlers (command, http)
├── conversation/store.ex     # persistence behaviour
├── scope/                    # Scope protocol + validation
├── llm/                      # LLM provider adapters
├── runtime/                  # agent spawning strategies
├── storage/                  # generic k/v backends
├── response/                 # LLM response shapes
├── types/                    # message structs
├── event/                    # streamed event structs
└── telemetry.ex              # `:telemetry` spans
```

If you are about to add a new top-level file inside `lib/skill_kit/`,
that is a signal you should be building a kit in the host app instead.
