# Handler Hooks Wiring Design

## Problem

The Server calls `Shell.execute(command, context)` directly for bash tool calls, bypassing the `Execution` pipeline and its `PreToolUse`/`PostToolUse` hooks. Hooks defined on skills never fire during agent conversations. Additionally, the handler is hardcoded to `Shell` with no way to swap it.

## Design

### Configurable Handler

The handler module is an application-level config:

```elixir
config :skill_kit, :handler, SkillKit.Tools.Shell
```

Read via `Application.get_env(:skill_kit, :handler, SkillKit.Tools.Shell)`. Same pattern as the LLM default provider.

### Handler.run/3

New 3-arity function that doesn't require a skill:

```elixir
def run(registry, command, context) do
  handler = Application.get_env(:skill_kit, :handler, SkillKit.Tools.Shell)
  all_hooks = collect_hooks(registry)
  execution = Execution.new(nil, command, context, all_hooks: all_hooks, handler: handler)
  Execution.run(execution)
end
```

The existing `run/4` (with skill) continues to work unchanged.

### Execution.new with nil skill

`Execution.new/4` currently reads the handler from `skill.handler`. When `skill` is nil, it reads the handler from the `:handler` option instead. Hook matchers still work — they match against the handler module name (e.g. `"Shell"`), not the skill.

Changes to `Execution.new/4`:
- Accept optional `:handler` in opts
- When skill is nil, use the `:handler` opt
- When skill is non-nil, use `skill.handler` (existing behavior)

### Server.execute_command

Changes from:
```elixir
Shell.execute(command, context)
```

To:
```elixir
skill_registry = {:via, Registry, {state.registry, {state.agent_name, :skill_registry}}}
SkillKit.Tool.Runner.run(skill_registry, command, context)
```

The result mapping stays the same — `{:ok, output}` → ToolResult, `{:error, {output, code}}` → error ToolResult. The `{:pending, _}` case from the Execution pipeline is handled as an error for now (pending/approval flow is out of scope).

### Hook Flow

With this wiring, a skill like:

```yaml
hooks:
  PostToolUse:
    - matcher: ".*"
      hooks:
        - type: command
          command: "echo 'hook fired'"
```

Will fire its PostToolUse hook after every bash command the agent runs.

## Scope

### In scope
- `config :skill_kit, :handler` application config
- `Handler.run/3` (no skill, uses configured handler)
- `Execution.new/4` handles nil skill with `:handler` opt
- Server routes bash through `Handler.run/3`
- Result mapping for `{:ok, _}`, `{:error, _}`, `{:pending, _}`

### Out of scope
- Approval/pending flow in the agent loop
- New hook phases (agent-level hooks like on_turn_end)
- Changing how hooks are defined in skill YAML (existing format works)
- Memory kit (separate feature, uses hooks once wired)

## Testing Strategy

- **Unit**: `Handler.run/3` collects hooks and runs pipeline with configured handler
- **Unit**: `Execution.new` with nil skill uses `:handler` opt
- **Unit**: PostToolUse hook fires after handler completes
- **Unit**: PreToolUse hook can deny execution
- **Integration**: Server bash tool call goes through hook pipeline
- **Config**: Default handler is Shell when no config set
