# Hooks and Execution

Every skill input runs through a structured pipeline: pre-hooks, the tool,
then post-hooks. This page explains how that pipeline is built and run, how
hooks are defined and matched, and how to suspend and resume execution for
human-in-the-loop approval flows.

## Overview

When `SkillKit.Tool.Runner.run/3,4` is called, it collects all hooks from every
registered skill, builds a `Pipeline` with hooks filtered to those
matching the tool (ordered as pre-steps, the execute step, and post-steps),
and walks it sequentially, recording each step's result by name.

A step that returns `{:pending, state}` suspends the pipeline. The caller
holds the execution struct and resumes it later with `Tool.Runner.resume/2`.

## Hook Struct

`SkillKit.Hook` carries three fields:

| Field      | Type                       | Description                                      |
|------------|----------------------------|--------------------------------------------------|
| `:phase`   | `:pre \| :post`             | When the hook fires relative to the execute step |
| `:matcher` | `Regex.t()`                | Matched against the last segment of the tool module name |
| `:handler` | `(map() -> any()) \| {m, f, a}` | The function to invoke                      |

Hooks are defined on a skill and scoped to its lifetime — when the skill is
unregistered, its hooks are removed from all future pipelines.

Pre-hook functions receive a context map with `:skill`, `:scope`, `:input`,
and `:tool`. Post-hook functions receive the same map plus `:result`, which
holds the execute step's return value.

A pre-hook may return:

- `:allow` — continue unchanged
- `{:allow, new_input}` — continue with a modified input map
- `{:deny, reason}` — halt the pipeline with a `:failed` status

## Execution Pipeline

### Construction

`SkillKit.Tool.Runner.run/3,4` builds the pipeline struct directly. It collects
hooks from the registry, filters them by tool name, builds the step list,
and constructs a `%Pipeline{}`:

```elixir
# Tool.Runner.run/4 does this internally:
%Pipeline{
  skill: skill,
  input: input,
  context: context,
  steps: pre_steps ++ [{:execute, "execute", tool}] ++ post_steps
}
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
case Pipeline.run(execution) do
  {:ok, exec}      -> exec.results["execute"]   # success
  {:error, exec}   -> exec.results             # inspect failures
  {:pending, exec} -> exec                      # hold for resumption
end
```

## The Three-Value Return

Every tool and hook ultimately returns one of three tagged tuples:

- `{:ok, result}` — the step completed; execution continues.
- `{:error, reason}` — the step failed; the pipeline halts with `:failed`.
- `{:pending, state}` — the step needs a decision; the pipeline suspends
  with `:suspended`, recording `state` in `execution.suspended_state`.

## Suspension and Resumption

When a step returns `{:pending, state}`, `Pipeline.run/1` returns
`{:pending, execution}` immediately. The pipeline does not advance further.

To continue, call `Tool.Runner.resume/2` (or `Pipeline.resume/2` directly):

```elixir
{:pending, exec} = Tool.Runner.run(catalog, skill, input, context)

case Tool.Runner.resume(exec, :approved) do
  {:ok, exec}      -> :done
  {:error, exec}   -> :denied_or_failed
  {:pending, exec} -> :another_approval_needed
end
```

`resume/2` replays from the suspended step — calling `resume/3` on the tool
for execute steps, or re-invoking the hook function for hook steps. The
`decision` value is passed straight through to `resume/3`.

## Tool Behaviour

Custom tools implement `SkillKit.Tool`:

```elixir
@callback execute(execution :: SkillKit.Pipeline.t()) ::
            {:ok, any()} | {:error, any()} | {:pending, any()}

@callback resume(execution :: SkillKit.Pipeline.t(), state :: any(),
                 decision :: :approved | {:denied, any()}) ::
            {:ok, any()} | {:error, any()} | {:pending, any()}

@callback definition() :: SkillKit.Tool.Definition.t()
```

`execute/1` receives the full execution struct. `resume/3` receives the same
struct, the `state` saved at suspension, and the caller's decision.
`definition/0` describes the tool for LLM tool-use schemas.

## Writing a Custom Tool

```elixir
defmodule MyApp.Tools.Sandbox do
  @behaviour SkillKit.Tool

  alias SkillKit.Pipeline

  @impl true
  def execute(%Pipeline{input: %{"command" => command}} = exec) do
    case MyApp.Sandbox.check_policy(command) do
      :allow   -> {:ok, MyApp.Sandbox.run(command)}
      :needs_approval -> {:pending, %{command: command}}
      {:deny, reason} -> {:error, {:denied, reason}}
    end
  end

  @impl true
  def resume(%Pipeline{} = exec, %{command: command}, :approved) do
    {:ok, MyApp.Sandbox.run(command)}
  end

  def resume(_exec, _state, {:denied, reason}) do
    {:error, {:denied, reason}}
  end

  @impl true
  def definition do
    %SkillKit.Tool.Definition{
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

To use a custom tool, create a kit module that `use SkillKit.Kit` and
implements the tool callbacks. Skills loaded by that kit will automatically
use it as their tool. Alternatively, register the tool via kit metadata:

```elixir
defmodule MyApp.SandboxKit do
  use SkillKit.Kit, name: "sandbox"

  @impl SkillKit.Tool
  def execute(execution), do: MyApp.Tools.Sandbox.execute(execution)

  @impl SkillKit.Tool
  def resume(execution, state, decision), do: MyApp.Tools.Sandbox.resume(execution, state, decision)

  @impl SkillKit.Tool
  def definition, do: MyApp.Tools.Sandbox.definition()
end
```

Then include it in your agent's skills:

```elixir
SkillKit.start_agent("agents/my-agent",
  skills: [MyApp.SandboxKit, "skills"]
)
```

The Catalog discovers tools by checking `kit.metadata.tool` — any kit
with a `:tool` key in its metadata registers itself as a tool. The
agent's Server uses `Catalog.tool_config/1` to find the active tool,
falling back to `SkillKit.Tools.Shell` if none is found.

## How Hooks Are Collected

Hooks are defined on skills and gathered at run time. `SkillKit.Tool.Runner.run/4`
calls `SkillKit.Catalog.hooks/1`, which flat-maps every skill's `:hooks` list
across all loaded kits, then filters by tool name and builds the step list
for the `%SkillKit.Pipeline{}` struct.

The matcher regex is tested against only the last segment of the tool module
name. A hook with `~r/Shell/` matches `SkillKit.Tools.Shell` but not
`MyApp.Tools.Sandbox`. A catch-all hook can use `~r/.*/`.

Because hooks are lifetime-scoped to their defining skill, unregistering a
skill implicitly deactivates all of its hooks for every subsequent pipeline run.
