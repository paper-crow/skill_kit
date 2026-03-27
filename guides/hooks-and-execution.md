# Hooks and Execution

Hooks fire at agent boundaries — moments where an agent is about to cross
into an external system or delegate to another process. They are gate-only:
a hook can allow, deny, or suspend a boundary crossing, but it cannot modify
the data flowing through it. Post-boundary hooks are fire-and-forget.

## Overview

Each boundary has a name (`:tool_use`, `:subagent`, `:llm_request`, etc.).
Pre-event names are derived as `pre_<boundary>` and post-event names as
`post_<boundary>`. For example, the `:tool_use` boundary fires
`:pre_tool_use` before tool execution and `:post_tool_use` after.

`SkillKit.Hooks` is the central dispatch module. It provides two entry
points:

- `Hooks.call/4` — gated boundary dispatch with a telemetry span. Runs
  pre-event hooks in order, executes the boundary action if all hooks
  allow, then fires post-event hooks in a cast (fire-and-forget). Returns
  `{:ok, result}`, `{:deny, reason}`, or `{:pending, state}`.
- `Hooks.cast/3` — fire-and-forget dispatch used for post-events. Hooks
  run asynchronously; their return values are ignored.

## Boundary Model

The 16 event names, grouped by boundary:

| Boundary | Pre-event | Post-event |
|---|---|---|
| `:tool_use` | `:pre_tool_use` | `:post_tool_use` |
| `:subagent` | `:pre_subagent` | `:post_subagent` |
| `:llm_request` | `:pre_llm_request` | `:post_llm_request` |
| `:skill_activation` | `:pre_skill_activation` | `:post_skill_activation` |
| `:message_send` | `:pre_message_send` | `:post_message_send` |
| `:agent_start` | `:pre_agent_start` | `:post_agent_start` |
| `:agent_stop` | `:pre_agent_stop` | `:post_agent_stop` |
| `:builtin` | `:pre_builtin` | `:post_builtin` |

In YAML frontmatter these are written in PascalCase: `PreToolUse`,
`PostToolUse`, `PreSubagent`, etc.

## Hook Struct

`%SkillKit.Hook{}` carries three fields:

| Field | Type | Description |
|---|---|---|
| `:event` | `atom()` | The boundary event this hook responds to (e.g. `:pre_tool_use`) |
| `:matcher` | `Regex.t() \| nil` | Matched against boundary-specific input. `nil` matches everything. |
| `:handler` | `{module, config} \| function \| mfa` | The handler to invoke |

Hooks are defined on skills and scoped to the skill's lifetime. Unregistering
a skill deactivates all of its hooks for every subsequent boundary crossing.

## Return Contract

Pre-event hooks return one of three values:

| Return | Meaning |
|---|---|
| `:ok` | Allow the boundary crossing to proceed |
| `{:deny, reason}` | Block the crossing; `Hooks.call/4` returns `{:deny, reason}` |
| `{:pending, state}` | Suspend; `Hooks.call/4` returns `{:pending, state}` for the caller to resume |

Post-event hooks (fired via `Hooks.cast/3`) run asynchronously. Their
return values are always ignored.

## Hooks Module

`SkillKit.Hooks.call/4` drives a gated boundary:

```elixir
# Hooks.call/4 signature:
# call(hooks, event, context, action_fn)
#
# hooks   — list of %Hook{} structs collected by the Catalog
# event   — the boundary event atom (e.g. :pre_tool_use)
# context — map passed to each matching hook handler
# action_fn — zero-arity function that performs the boundary action

case Hooks.call(hooks, :pre_tool_use, context, fn -> Tool.execute(execution) end) do
  {:ok, result}      -> result
  {:deny, reason}    -> {:error, {:denied, reason}}
  {:pending, state}  -> {:suspended, state}
end
```

`SkillKit.Hooks.cast/3` fires post-event hooks without blocking:

```elixir
# cast/3 signature:
# cast(hooks, event, context)
Hooks.cast(hooks, :post_tool_use, Map.put(context, :result, result))
```

## Matcher Semantics

Each boundary matches the hook's `:matcher` regex against a boundary-specific
string. A `nil` matcher matches everything.

| Boundary | Matched against |
|---|---|
| `:tool_use` | Tool name (e.g. `"bash"`, `"files:read"`) |
| `:subagent` | Agent name (e.g. `"code-reviewer"`) |
| `:llm_request` | Model string (e.g. `"claude-sonnet-4-20250514"`) |
| `:skill_activation` | Skill name (e.g. `"system:memory"`) |
| `:message_send` | Message role (`"user"`, `"assistant"`) |
| `:agent_start` | Agent name |
| `:agent_stop` | Agent name |
| `:builtin` | Builtin function name (e.g. `"report_result"`) |

## Handler Behaviour

Custom handlers implement `SkillKit.Hooks.Handler`:

```elixir
@callback execute(config :: map(), context :: map()) ::
  :ok | {:deny, reason :: any()} | {:pending, state :: any()}
```

The `config` map comes from the hook definition (e.g. the YAML frontmatter
values). The `context` map contains boundary-specific information (see
[Hook Context Maps](#hook-context-maps) below).

### Built-in Handlers

**Command** — runs an OS command and interprets its exit code:

```yaml
hooks:
  PreToolUse:
    - matcher: "bash"
      hooks:
        - type: command
          command: "check-policy $TOOL_NAME"
```

Exit code `0` → `:ok`. Exit code `1` → `{:deny, stderr}`. Any other code →
`{:pending, state}` (suspend for human review).

**Http** — POSTs the context to an HTTP endpoint and interprets the response:

```yaml
hooks:
  PreSubagent:
    - matcher: ".*"
      hooks:
        - type: http
          url: "https://policy.example.com/approve"
```

HTTP `200` → `:ok`. HTTP `403` → `{:deny, body}`. HTTP `202` →
`{:pending, state}` (suspend awaiting callback).

## Configuring Handler Types

Register handler modules via application config or per-agent option:

```elixir
# config/config.exs
config :skill_kit, SkillKit.Hooks,
  handlers: %{
    "command" => SkillKit.Hooks.Handlers.Command,
    "http"    => SkillKit.Hooks.Handlers.Http,
    "my_type" => MyApp.Hooks.CustomHandler
  }
```

Or override at agent start:

```elixir
SkillKit.start_agent("agents/neve",
  skills: ["skills"],
  hook_handlers: %{
    "audit" => MyApp.Hooks.AuditHandler
  }
)
```

Per-agent `hook_handlers` merges with (and overrides) the application config.

## Tool Execution

`SkillKit.ToolExecution` handles the actual tool invocation after hooks have
cleared the boundary. It exposes two operations:

- `ToolExecution.execute/1` — runs the tool. Returns `{:ok, result}`,
  `{:error, reason}`, or `{:pending, state}` if the tool itself needs to
  suspend.
- `ToolExecution.resume/2` — resumes a suspended tool with a decision
  (`decision` is `:approved` or `{:denied, reason}`).

Hooks are not part of the `ToolExecution` pipeline. The `Agent.Server`
calls `Hooks.call/4` before dispatching to `ToolExecution`.

## Defining Hooks in Skills

Hooks are declared in YAML frontmatter under the `hooks` key, using the same
nested structure as Claude Code. Each event key maps to a list of matchers,
each with its own list of handler entries:

```markdown
---
name: "ops:deploy"
description: Deploy a service to the staging environment.
hooks:
  PreToolUse:
    - matcher: "bash"
      hooks:
        - type: command
          command: "check-deploy-policy"
  PostToolUse:
    - matcher: ".*"
      hooks:
        - type: http
          url: "https://audit.example.com/log"
  PreSubagent:
    - matcher: ".*"
      hooks:
        - type: command
          command: "echo 'delegating to subagent'"
---
Deploy $ARGUMENTS to staging.
```

All 16 event names in YAML (PascalCase):

```
PreToolUse    PostToolUse
PreSubagent   PostSubagent
PreLlmRequest PostLlmRequest
PreSkillActivation  PostSkillActivation
PreMessageSend      PostMessageSend
PreAgentStart       PostAgentStart
PreAgentStop        PostAgentStop
PreBuiltin          PostBuiltin
```

## Hook Context Maps

Each boundary passes a context map to matching handlers. Common keys are
present in every context; boundary-specific keys are listed separately.

**Common keys** (all boundaries):

| Key | Type | Description |
|---|---|---|
| `:agent_name` | `atom()` | Name of the agent firing the hook |
| `:event` | `atom()` | The boundary event atom |
| `:skill` | `SkillKit.Skill.t() \| nil` | The skill that owns the hook |

**Boundary-specific keys:**

| Boundary | Additional keys |
|---|---|
| `:tool_use` | `:tool_name`, `:tool_input` (map) |
| `:subagent` | `:subagent_name`, `:task` (string) |
| `:llm_request` | `:model` (string), `:message_count` |
| `:skill_activation` | `:skill_name`, `:arguments` (string) |
| `:message_send` | `:role` (string), `:content` |
| `:agent_start` | `:agent_name`, `:definition` |
| `:agent_stop` | `:agent_name`, `:reason` |
| `:builtin` | `:function_name`, `:arguments` |

Post-events receive the same context as their pre-event counterpart, plus
a `:result` key holding the outcome of the boundary action.
