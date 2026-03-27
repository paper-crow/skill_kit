# Hooks and Execution

Hooks fire at agent boundaries — moments where an agent is about to cross
into an external system or delegate to another process. They are gate-only:
a hook can allow, deny, or suspend a boundary crossing, but it cannot modify
the data flowing through it. Post-boundary hooks are fire-and-forget (their
return values are ignored).

## Overview

Each boundary has a name (`:tool_use`, `:subagent`, `:llm_request`, etc.).
Pre-event names are derived as `pre_<boundary>` and post-event names as
`post_<boundary>`. For example, the `:tool_use` boundary fires
`:pre_tool_use` before tool execution and `:post_tool_use` after.

`SkillKit.Hooks` is the central dispatch module. It provides two entry
points:

- `Hooks.call/4` — gated boundary dispatch with a telemetry span. Runs
  pre-event hooks in order, executes the boundary action if all hooks
  allow, then fires post-event hooks synchronously with their return values
  discarded. Returns the result of the action, `{:deny, reason}`, or
  `{:pending, state}`.
- `Hooks.cast/3` — fire-and-forget dispatch. Hooks run synchronously but
  their return values are ignored.

## Boundary Model

The 16 event names, grouped by boundary:

| Boundary | Pre-event | Post-event | What it gates |
|---|---|---|---|
| `:tool_use` | `:pre_tool_use` | `:post_tool_use` | OS command or module-skill tool execution |
| `:subagent` | `:pre_subagent` | `:post_subagent` | Spawning a subagent |
| `:skill_activation` | `:pre_skill_activation` | `:post_skill_activation` | Activating a skill |
| `:conversation_save` | `:pre_conversation_save` | `:post_conversation_save` | Persisting conversation history |
| `:conversation_load` | `:pre_conversation_load` | `:post_conversation_load` | Loading conversation history |
| `:llm_request` | `:pre_llm_request` | `:post_llm_request` | Sending a request to the LLM |
| `:turn` | `:pre_turn` | `:post_turn` | Processing a batch of messages (one agent loop) |
| `:agent` | `:pre_agent` | `:post_agent` | Agent process lifecycle (init/terminate) |

The `:agent` boundary fires via `Hooks.cast/3` — `pre_agent` on init and
`post_agent` on terminate. Return values from these hooks are always ignored.

In YAML frontmatter these event names are written in PascalCase: `PreToolUse`,
`PostToolUse`, `PreSubagent`, etc.

## Hook Struct

`%SkillKit.Hook{}` carries three fields:

| Field | Type | Description |
|---|---|---|
| `:event` | `atom()` | The boundary event this hook responds to (e.g. `:pre_tool_use`) |
| `:matcher` | `Regex.t() \| nil` | Matched against a boundary-specific string. `nil` matches everything. |
| `:handler` | `{module, config} \| (map() -> any()) \| {module, atom, list}` | The handler to invoke |

Hooks are defined on skills and scoped to the skill's lifetime. Unregistering
a skill deactivates all of its hooks for every subsequent boundary crossing.

## Return Contract

Pre-event hooks return one of three values:

| Return | Meaning |
|---|---|
| `:ok` | Allow the boundary crossing to proceed |
| `{:deny, reason}` | Block the crossing; `Hooks.call/4` returns `{:deny, reason}` to the caller |
| `{:pending, state}` | Suspend; `Hooks.call/4` returns `{:pending, state}` to the caller |

`Hooks.call/4` evaluates pre-event hooks in list order and stops at the first
`:deny` or `:pending`. If all pre-event hooks return `:ok`, the boundary
action runs. Post-event hooks always run synchronously after the action, but
their return values are discarded.

## Hooks Module

`SkillKit.Hooks.call/4` drives a gated boundary:

```elixir
@spec call(GenServer.server(), atom(), map(), (-> {term(), map()})) :: term()
```

The callback must return `{result, post_context}`:

- **`result`** — returned to the caller of `call/4` (or `{:deny, reason}` / `{:pending, state}` if a pre-hook intervened)
- **`post_context`** — passed to `:post_<boundary>` hooks. By convention, this is the original context with `:result` added so post-hooks can observe the outcome.

```elixir
Hooks.call(catalog, :tool_use, context, fn ->
  result = do_work()
  {result, Map.put(context, :result, result)}
end)
```

The boundary name drives both the telemetry span (`:tool_use` becomes
`[:skill_kit, :tool_use, :start/:stop]`) and the hook event names
(`:pre_tool_use` / `:post_tool_use`).

`SkillKit.Hooks.cast/3` fires a single hook event without gating:

```elixir
# cast/3 signature:
# cast(catalog, event, context)
Hooks.cast(catalog, :post_subagent, %{name: name, result: result, agent_name: agent_name})
```

## Matcher Semantics

Each boundary matches the hook's `:matcher` regex against a
boundary-specific string. A `nil` matcher matches everything.

| Boundary | Matched against |
|---|---|
| `:tool_use` | Last segment of the tool module name (e.g. `"Shell"`) |
| `:subagent` | Subagent name from context `:name` key, falling back to `:agent_name` |
| `:skill_activation` | Skill name string (e.g. `"ops:deploy"`) |
| `:llm_request` | Model string from context `:model` key, falling back to `:agent_name` |
| All others | Agent name string from `:agent_name` key |

## Handler Behaviour

Custom handlers implement `SkillKit.Hooks.Handler`:

```elixir
@callback execute(config :: map(), context :: map()) ::
  :ok | {:deny, reason :: any()} | {:pending, state :: any()}
```

The `config` map comes from the hook definition (the YAML fields minus
`type`). The `context` map contains boundary-specific information (see
[Hook Context Maps](#hook-context-maps) below).

Three handler forms are supported:

- `{module, config}` — calls `module.execute(config, context)`
- `fun/1` — calls `fun.(context)`
- `{module, fun, args}` — calls `apply(module, fun, [context | args])`

### Built-in Handlers

**Command** — runs an OS command. The hook context is passed as JSON in the
`HOOK_INPUT` environment variable.

Exit code semantics (matching Claude Code):

| Exit code | Result |
|---|---|
| `0` | `:ok` (allow) |
| `2` | `{:deny, output}` (block) |
| Any other | `:ok` (non-blocking error) |

```yaml
hooks:
  PreToolUse:
    - matcher: "Shell"
      hooks:
        - type: command
          command: "check-deploy-policy"
```

**Http** — POSTs the context as JSON to a URL.

Response semantics:

| Response | Result |
|---|---|
| 2xx with `{"decision": "deny", "reason": "..."}` | `{:deny, reason}` |
| 2xx with `{"decision": "allow"}` or no `decision` field | `:ok` |
| Non-2xx | `{:deny, "HTTP hook returned status <code>"}` |
| Connection error | `:ok` (non-blocking, matches Claude Code) |

```yaml
hooks:
  PreSubagent:
    - matcher: ".*"
      hooks:
        - type: http
          url: "https://policy.example.com/approve"
          timeout: 30
```

Optional `headers` map and `timeout` (seconds, default 30) are supported.

## Configuring Handler Types

Handler modules are registered via application config:

```elixir
# config/config.exs
config :skill_kit, :hook_handlers, %{
  "command" => SkillKit.Hooks.Command,
  "http"    => SkillKit.Hooks.Http,
  "my_type" => MyApp.Hooks.CustomHandler
}
```

The parser reads this map at skill load time to resolve `type:` strings
to handler modules. Unknown types log a warning and default to a no-op
handler that always returns `:ok`.

## Tool Execution

`SkillKit.ToolExecution` manages the actual tool invocation after hooks have
cleared the boundary. It exposes two operations:

- `ToolExecution.execute/1` — runs the tool. Returns `{:ok, execution}`,
  `{:error, execution}`, or `{:pending, execution}` if the tool suspends.
- `ToolExecution.resume/2` — resumes a suspended execution. Takes the
  execution struct and a decision value, passes it to the tool's `resume/3`
  callback.

Hooks are not part of the `ToolExecution` pipeline. `Agent.Server` calls
`Hooks.call/4` before dispatching to `ToolExecution`.

## Defining Hooks in Skills

Hooks are declared in YAML frontmatter under the `hooks` key. Each event key
maps to a list of entries, each with an optional `matcher` and a `hooks` list
of handler configs:

```markdown
---
name: "ops:deploy"
description: Deploy a service to the staging environment.
hooks:
  PreToolUse:
    - matcher: "Shell"
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
PreToolUse              PostToolUse
PreSubagent             PostSubagent
PreSkillActivation      PostSkillActivation
PreConversationSave     PostConversationSave
PreConversationLoad     PostConversationLoad
PreLlmRequest           PostLlmRequest
PreTurn                 PostTurn
PreAgent                PostAgent
```

Unknown event names are silently ignored.

## Hook Context Maps

Each boundary passes a context map to matching handlers. The keys vary by
boundary.

**`:tool_use`** (pre and post):

| Key | Type | Description |
|---|---|---|
| `:tool` | `module()` | The tool module being invoked |
| `:input` | `map()` | Tool input arguments |
| `:skill` | `Skill.t() \| nil` | The skill that triggered the tool call, if any |
| `:scope` | `term()` | The agent's authorization scope |
| `:agent_name` | `String.t()` | Name of the agent |

Post-event also includes `:result` with the tool outcome.

**`:subagent`** (pre):

| Key | Type | Description |
|---|---|---|
| `:name` | `String.t()` | The subagent's definition name |
| `:task` | `String.t()` | The task being delegated |
| `:agent_name` | `String.t()` | Name of the parent agent |
| `:depth` | `non_neg_integer()` | Current agent nesting depth |

**`:subagent`** (post, via `cast/3`):

| Key | Type | Description |
|---|---|---|
| `:name` | `String.t()` | The subagent's definition name |
| `:task` | `String.t()` | The task that was delegated |
| `:result` | `String.t()` | The subagent's reported result |
| `:agent_name` | `String.t()` | Name of the parent agent |

**`:skill_activation`**:

| Key | Type | Description |
|---|---|---|
| `:skill` | `Skill.t()` | The skill being activated |
| `:skill_name` | `String.t()` | The skill's name string |
| `:arguments` | `String.t()` | Arguments passed to the skill |
| `:agent_name` | `String.t()` | Name of the agent |
| `:scope` | `term()` | The agent's authorization scope |

**`:llm_request`**:

| Key | Type | Description |
|---|---|---|
| `:agent_name` | `String.t()` | Name of the agent |
| `:model` | `String.t()` | Model identifier string |
| `:message_count` | `non_neg_integer()` | Number of messages in context |
| `:tool_count` | `non_neg_integer()` | Number of tools available |

**`:turn`**:

| Key | Type | Description |
|---|---|---|
| `:agent_name` | `String.t()` | Name of the agent |
| `:message_count` | `non_neg_integer()` | Number of new messages in this turn |

**`:conversation_save`**:

| Key | Type | Description |
|---|---|---|
| `:agent_name` | `String.t()` | Name of the agent |
| `:message_count` | `non_neg_integer()` | Total messages being saved |

**`:agent`** (pre/post, via `cast/3`):

| Key | Type | Description |
|---|---|---|
| `:agent_name` | `String.t()` | Name of the agent |
| `:definition` | `Definition.t()` | The agent's definition struct |
