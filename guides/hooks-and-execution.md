# Hooks and Execution

Every skill input runs through a structured pipeline: pre-hooks, the handler,
then post-hooks. This page explains how that pipeline is built and run, how
hooks are defined and matched, and how to suspend and resume execution for
human-in-the-loop approval flows.

## Overview

When `SkillKit.Handler.run/3,4` is called, it collects all hooks from every
registered skill, builds an `Execution` pipeline with hooks filtered to those
matching the handler (ordered as pre-steps, the execute step, and post-steps),
and walks it sequentially, recording each step's result by name.

A step that returns `{:pending, state}` suspends the pipeline. The caller
holds the execution struct and resumes it later with `Handler.resume/2`.

## Hook Struct

`SkillKit.Hook` carries three fields:

| Field      | Type                       | Description                                      |
|------------|----------------------------|--------------------------------------------------|
| `:phase`   | `:pre \| :post`             | When the hook fires relative to the execute step |
| `:matcher` | `Regex.t()`                | Matched against the last segment of the handler module name |
| `:handler` | `(map() -> any()) \| {m, f, a}` | The function to invoke                      |

Hooks are defined on a skill and scoped to its lifetime — when the skill is
unregistered, its hooks are removed from all future pipelines.

Pre-hook functions receive a context map with `:skill`, `:scope`, `:input`,
and `:handler`. Post-hook functions receive the same map plus `:result`, which
holds the execute step's return value.

A pre-hook may return:

- `:allow` — continue unchanged
- `{:allow, new_input}` — continue with a modified input map
- `{:deny, reason}` — halt the pipeline with a `:failed` status

## Execution Pipeline

### Construction

`Execution.new/4` accepts a skill (or `nil`), an input map, a context map, and
options. The `all_hooks:` option supplies every hook to consider — `new/4`
filters them to those whose `:matcher` regex matches the handler's module name.

```elixir
execution = Execution.new(skill, input, context, all_hooks: hooks)
```

### Step Names

Steps are named for introspection and resumption:

- Pre-hooks: `"pre:0"`, `"pre:1"`, ...
- Execute step: `"execute"`
- Post-hooks: `"post:0"`, `"post:1"`, ...

Results accumulate in `execution.results`, a map keyed by step name.

### Status Transitions

| Status       | Meaning                                   |
|--------------|-------------------------------------------|
| `:pending`   | Built but not yet run                     |
| `:running`   | Actively walking steps                    |
| `:suspended` | Paused at a step awaiting a decision      |
| `:complete`  | All steps succeeded                       |
| `:failed`    | A step returned an error or denial        |

### Running

```elixir
case Execution.run(execution) do
  {:ok, exec}      -> exec.results["execute"]   # success
  {:error, exec}   -> exec.results             # inspect failures
  {:pending, exec} -> exec                      # hold for resumption
end
```

## The Three-Value Return

Every handler and hook ultimately returns one of three tagged tuples:

- `{:ok, result}` — the step completed; execution continues.
- `{:error, reason}` — the step failed; the pipeline halts with `:failed`.
- `{:pending, state}` — the step needs a decision; the pipeline suspends
  with `:suspended`, recording `state` in `execution.suspended_state`.

## Suspension and Resumption

When a step returns `{:pending, state}`, `Execution.run/1` returns
`{:pending, execution}` immediately. The pipeline does not advance further.

To continue, call `Handler.resume/2` (or `Execution.resume/2` directly):

```elixir
{:pending, exec} = Handler.run(registry, skill, input, context)

case Handler.resume(exec, :approved) do
  {:ok, exec}      -> :done
  {:error, exec}   -> :denied_or_failed
  {:pending, exec} -> :another_approval_needed
end
```

`resume/2` replays from the suspended step — calling `resume/3` on the handler
for execute steps, or re-invoking the hook function for hook steps. The
`decision` value is passed straight through to `resume/3`.

## Handler Behaviour

Custom handlers implement `SkillKit.Handler.Behaviour`:

```elixir
@callback execute(execution :: SkillKit.Execution.t()) ::
            {:ok, any()} | {:error, any()} | {:pending, any()}

@callback resume(execution :: SkillKit.Execution.t(), state :: any(),
                 decision :: :approved | {:denied, any()}) ::
            {:ok, any()} | {:error, any()} | {:pending, any()}

@callback tool_definition() :: SkillKit.Handler.ToolDefinition.t()
```

`execute/1` receives the full execution struct. `resume/3` receives the same
struct, the `state` saved at suspension, and the caller's decision.
`tool_definition/0` describes the tool for LLM tool-use schemas.

## Writing a Custom Handler

```elixir
defmodule MyApp.Handler.Sandbox do
  @behaviour SkillKit.Handler.Behaviour

  alias SkillKit.Execution

  @impl true
  def execute(%Execution{input: %{"command" => command}} = exec) do
    case MyApp.Sandbox.check_policy(command) do
      :allow   -> {:ok, MyApp.Sandbox.run(command)}
      :needs_approval -> {:pending, %{command: command}}
      {:deny, reason} -> {:error, {:denied, reason}}
    end
  end

  @impl true
  def resume(%Execution{} = exec, %{command: command}, :approved) do
    {:ok, MyApp.Sandbox.run(command)}
  end

  def resume(_exec, _state, {:denied, reason}) do
    {:error, {:denied, reason}}
  end

  @impl true
  def tool_definition do
    %SkillKit.Handler.ToolDefinition{
      name: "sandbox",
      description: "Run a command in the sandbox environment.",
      input_schema: %{
        "type" => "object",
        "properties" => %{"command" => %{"type" => "string"}},
        "required" => ["command"]
      }
    }
  end
end
```

Configure SkillKit to use it:

```elixir
config :skill_kit, handler: MyApp.Handler.Sandbox
```

## How Hooks Are Collected

Hooks are defined on skills and gathered at run time. `SkillKit.Handler.run/3` calls
`SkillKit.Registry.list_skills/2` and flat-maps each skill's `:hooks` list into a
single collection before passing it to `SkillKit.Execution.new/4`.

The matcher regex is tested against only the last segment of the handler module
name. A hook with `~r/Shell/` matches `SkillKit.Handler.Shell` but not
`MyApp.Handler.Sandbox`. A catch-all hook can use `~r/.*/`.

Because hooks are lifetime-scoped to their defining skill, unregistering a
skill implicitly deactivates all of its hooks for every subsequent pipeline run.
