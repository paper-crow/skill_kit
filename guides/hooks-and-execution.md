# Hooks

Hooks let skills enforce policy at agent boundaries — moments where an
agent is about to execute a tool, spawn a subagent, call the LLM, or
persist a conversation. They are gate-only: a hook can allow, deny, or
suspend the action, but never modify the data flowing through it.

## Defining Hooks on Skills

Hooks are declared in a skill's YAML frontmatter under the `hooks` key.
Each event name maps to a list of matcher entries, each with a list of
handler configs:

```yaml
---
name: ops:deploy
description: Deploy a service to staging.
hooks:
  PreToolUse:
    - matcher: "Shell"
      hooks:
        - type: command
          command: "./scripts/check-deploy-policy.sh"
  PostToolUse:
    - hooks:
        - type: http
          url: "https://audit.example.com/log"
---
Deploy $ARGUMENTS to staging.
```

Hooks are scoped to the skill's lifetime. When the skill is unregistered,
its hooks stop firing.

## Available Events

Each boundary has a pre-event (can deny) and a post-event (observational).
Use PascalCase in YAML frontmatter:

| Pre-event | Post-event | What it gates |
|---|---|---|
| `PreToolUse` | `PostToolUse` | OS command or module-skill tool execution |
| `PreSubagent` | `PostSubagent` | Spawning a subagent |
| `PreSkillActivation` | `PostSkillActivation` | Activating a skill |
| `PreLlmRequest` | `PostLlmRequest` | Sending a request to the LLM provider |
| `PreConversationSave` | `PostConversationSave` | Persisting conversation history |
| `PreConversationLoad` | `PostConversationLoad` | Loading conversation history |
| `PreTurn` | `PostTurn` | Processing a batch of messages (one agent loop) |
| `PreAgent` | `PostAgent` | Agent process init / terminate |

Unknown event names are silently ignored.

## Matchers

The optional `matcher` field is a regex that filters which boundary
crossings trigger the hook. What it matches against depends on the
boundary:

| Boundary | Matched against | Example |
|---|---|---|
| Tool use | Last segment of tool module name | `"Shell"`, `"Sandbox"` |
| Subagent | Subagent name | `"researcher"` |
| Skill activation | Skill name | `"ops:deploy"` |
| LLM request | Model string | `"claude-opus"` |
| All others | Agent name | `"my-agent"` |

Omit `matcher` to match all crossings for that event.

## Return Values

Pre-event hook handlers return one of:

| Return | Effect |
|---|---|
| `:ok` | Allow — proceed to the next hook or the action |
| `{:deny, reason}` | Block — the action does not run |
| `{:pending, state}` | Suspend — the action pauses for approval |

Pre-hooks run in order. The first `:deny` or `:pending` short-circuits —
remaining hooks and the action itself are skipped.

Post-event hooks always run after the action completes. Their return
values are ignored.

## Built-in Handler Types

### Command

Shells out to a command. The hook context is passed as JSON in the
`HOOK_INPUT` environment variable.

```yaml
hooks:
  PreToolUse:
    - matcher: "Shell"
      hooks:
        - type: command
          command: "./scripts/validate.sh"
```

Exit code semantics (matching Claude Code):

| Exit code | Result |
|---|---|
| `0` | `:ok` |
| `2` | `{:deny, output}` |
| Any other | `:ok` (non-blocking error) |

### Http

POSTs the hook context as JSON to a URL.

```yaml
hooks:
  PreSubagent:
    - hooks:
        - type: http
          url: "https://policy.example.com/approve"
          timeout: 10
```

Response interpretation:

| Response | Result |
|---|---|
| 2xx with `{"decision": "deny", "reason": "..."}` | `{:deny, reason}` |
| 2xx with `{"decision": "allow"}` or no `decision` field | `:ok` |
| Non-2xx | `{:deny, "HTTP hook returned status <code>"}` |
| Connection error | `:ok` (non-blocking) |

Optional fields: `headers` (map), `timeout` (seconds, default 30).

## Custom Handler Types

Implement `SkillKit.Hooks.Handler`:

```elixir
defmodule MyApp.Hooks.Slack do
  @behaviour SkillKit.Hooks.Handler

  @impl true
  def execute(%{"channel" => channel} = config, context) do
    message = Map.get(config, "message", "Hook fired")
    MyApp.Slack.post(channel, "#{message}: #{inspect(context)}")
    :ok
  end
end
```

Register the type in application config:

```elixir
# config/config.exs
config :skill_kit, :hook_handlers, %{
  "command" => SkillKit.Hooks.Command,
  "http" => SkillKit.Hooks.Http,
  "slack" => MyApp.Hooks.Slack
}
```

Or per-agent via `start_agent`:

```elixir
SkillKit.start_agent("agents/my-agent",
  skills: ["skills"],
  hook_handlers: %{"slack" => MyApp.Hooks.Slack}
)
```

Skills can then reference the custom type in YAML:

```yaml
hooks:
  PostToolUse:
    - hooks:
        - type: slack
          channel: "#deployments"
          message: "Tool executed"
```

The remaining YAML fields (everything except `type`) become the `config`
map passed to your handler's `execute/2`.

## Programmatic Hooks

Module-based kits and tests can define hooks directly on skill structs
using function or MFA handlers:

```elixir
%Skill{
  name: "policy:enforcer",
  hooks: [
    %Hook{
      event: :pre_tool_use,
      matcher: ~r/Shell/,
      handler: fn context -> check_policy(context) end
    }
  ]
}
```

## Hook Context

Each boundary passes a context map to matching handlers. Common keys
across all boundaries:

| Key | Type | Present on |
|---|---|---|
| `:agent_name` | `String.t()` | All boundaries |
| `:scope` | `term()` | Tool use, skill activation |

Boundary-specific keys:

| Boundary | Additional keys |
|---|---|
| Tool use | `:tool` (module), `:input` (map), `:skill` (Skill.t or nil) |
| Tool use (post) | Same + `:result` |
| Subagent | `:name`, `:task`, `:depth` |
| Subagent (post) | `:name`, `:task`, `:result` |
| Skill activation | `:skill` (Skill.t), `:skill_name`, `:arguments` |
| LLM request | `:model`, `:message_count`, `:tool_count` |
| Conversation save | `:message_count` |
| Agent | `:definition` (Definition.t) |
| Turn | `:message_count` |
