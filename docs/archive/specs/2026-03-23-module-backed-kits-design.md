# Module-Backed Kits & Scheduler

## Problem

Skills today are `.skill.md` files executed via the Shell handler. There is no mechanism for skills to call into the host application's BEAM — no access to Ecto, Oban, PubSub, or any Elixir module. This limits SkillKit to shelling out for all tool execution.

The immediate need is a scheduler skill backed by Oban, but the underlying gap is general: skills cannot reach into the application.

## Design

### 1. `use SkillKit.Kit` — compile-time kit loading

A Kit module loads `.skill.md` files from a companion `skills/` directory at compile time and handles execution for its skills.

```
lib/skill_kit/scheduler/
  scheduler.ex              # use SkillKit.Kit — loads skills/, handles execute/1
  worker.ex                 # Oban worker
  skills/
    schedule.skill.md
    cancel.skill.md
```

```elixir
defmodule SkillKit.Scheduler do
  use SkillKit.Kit

  alias SkillKit.Execution

  def execute(%Execution{skill: %{name: "scheduler:schedule"}, input: input, context: context}) do
    oban = context[:oban] || Oban
    agent = context[:agent_name]

    %{agent: agent, prompt: input["prompt"]}
    |> SkillKit.Scheduler.Worker.new(schedule_opts(input["schedule"]))
    |> Oban.insert(oban)
  end

  def execute(%Execution{skill: %{name: "scheduler:cancel"}, input: input, context: context}) do
    oban = context[:oban] || Oban
    Oban.cancel_job(oban, input["job_id"])
  end
end
```

The `use SkillKit.Kit` macro:

- Implements `SkillKit.Backend` on behalf of the module.
- At compile time, reads `*.skill.md` files from a `skills/` directory relative to the module's source file. Uses `@external_resource` so the module recompiles when skill files change.
- Infers the kit name from the module's last segment, downcased and underscored (e.g., `SkillKit.Scheduler` → `"scheduler"`). Override with `name:` option.
- Sets the Kit module as the handler for all loaded skills (replaces `SkillKit.Handler.Shell`).
- `load_kits/1` returns `{:ok, [%Kit{}]}` containing the parsed skills.
- Stores the source config (the keyword list from the `{Module, config}` tuple in `:sources`) on each `%Skill{}` via `metadata["source_config"]`. This config is merged into the execution context so the Kit can access it (e.g., `oban: MyApp.Oban`).
- Implements `SkillKit.Handler.Behaviour` on behalf of the module — generates `tool_definition/0` and a default `resume/3` that returns `{:error, :not_resumable}`. The module implements `execute/1` taking an `%Execution{}` struct.

Skills remain standard `.skill.md` files — no frontmatter extensions. The Kit module automatically becomes the handler. The skill body teaches the LLM what input to provide. Tool definitions are built from skill `name` + `description` with an open `{type: object}` input schema.

Host app config:

```elixir
config :skill_kit, :sources, [
  {SkillKit.Backend.Filesystem, path: "priv/kits"},
  {SkillKit.Scheduler, oban: MyApp.Oban}
]
```

### 2. Handler interface: `command` → `input`, single `Execution` arg

Rename the `command` field to `input`, widen the type from `String.t()` to `map()`, and pass the entire `Execution` struct to handlers.

#### Behaviour change

```elixir
# Before
@callback execute(command :: String.t(), context :: map()) :: ...
@callback resume(state :: any(), decision :: :approved | {:denied, any()}, context :: map()) :: ...

# After
@callback execute(execution :: SkillKit.Execution.t()) :: ...
@callback resume(execution :: SkillKit.Execution.t(), state :: any(), decision :: :approved | {:denied, any()}) :: ...
```

The full `Execution` struct is passed. Handlers destructure what they need — `skill`, `input`, `context`. This eliminates `build_execute_context/1` entirely.

#### Affected modules

| Module | Change |
|--------|--------|
| `Handler.Behaviour` | `execute/2` → `execute/1`, `resume/3` → `resume/3`, takes `Execution` |
| `Handler.Shell` | Destructures `%Execution{input: %{"command" => command}, context: ctx}` |
| `Execution` | `command:` field → `input:`, type `String.t()` → `map()` |
| `Execution` | `update_command/2` → `update_input/2` |
| `Execution` | `build_pre_context` — `:command` key → `:input` |
| `Execution` | `walk_steps` — passes `exec` directly to `handler_mod.execute/1` |
| `Execution` | Remove `build_execute_context/1` — no longer needed |
| `Handler` (public API) | `run(registry, command, ctx)` — param rename to `input` |
| `Agent.Server` | Remove `Map.get(input, "command", "")` unwrap at line 287, pass `input` map directly |

#### Shell handler update

```elixir
def execute(%Execution{input: %{"command" => command}, context: context}) do
  # existing Port.open logic unchanged
end

def resume(%Execution{} = exec, _state, :approved) do
  execute(exec)
end
```

#### Execution pipeline

```elixir
defp walk_steps([{:execute, _name, handler_mod} | _rest] = steps, exec) do
  apply_step_result(steps, exec, handler_mod.execute(exec))
end
```

#### Hook rewrite compatibility

Pre-hooks can currently return `{:allow, new_cmd}` to rewrite the command. With the input change, this becomes `{:allow, new_input}` where `new_input` is a map. Hooks that rewrite Shell commands return `{:allow, %{"command" => "new command"}}`.

### 3. Dispatch: how module-backed skills reach execution

Today, `ToolBuilder` assumes a single global handler. All tool calls classified as `:handler` hit `execute_command/2`, which calls `Handler.run/3` with the global handler. Module-backed skills need per-tool dispatch.

#### Activation flow

Module-backed skills go through `activate_skill` like any other skill. All skills appear in the `activate_skill` enum with their description. The agent activates a skill to load its body/instructions into context. The skill body teaches the agent WHEN and HOW to use the tool.

The key difference: activating a module-backed skill also adds its tool to the tool list. Before activation, the tool is not available. This keeps the tool list lean — tools appear only when the agent needs them.

#### Agent state

Add `activated_skills` to the agent server state — a list of `%Skill{}` structs that have been activated and have non-Shell handlers:

```elixir
# In Agent.Server state
%{
  # ... existing fields ...
  activated_skills: []  # module-backed skills activated this session
}
```

#### activate_skill changes

When a module-backed skill is activated, add it to `activated_skills` in addition to injecting the body:

```elixir
defp activate_skill(%Message.ToolCall{} = tc, state) do
  skill = find_skill(tc.input["name"], state)
  body = Skill.render(skill, tc.input)

  # Track activation for module-backed skills
  state =
    if skill.handler != SkillKit.Handler.Shell do
      %{state | activated_skills: [skill | state.activated_skills]}
    else
      state
    end

  {%Message.ToolResult{tool_call_id: tc.id, content: body}, state}
end
```

#### ToolBuilder changes

`build_tools/2` accepts activated skills and includes their tool definitions:

```elixir
def build_tools(kits, opts \\ []) do
  handlers = Keyword.get(opts, :handlers, [SkillKit.Handler.Shell])
  activated_skills = Keyword.get(opts, :activated_skills, [])
  all_skills = Enum.flat_map(kits, & &1.skills)

  handler_tools = Enum.map(handlers, & &1.tool_definition())

  # Activated module-backed skills get their own tools
  activated_tools = Enum.map(activated_skills, &skill_to_tool/1)

  # All skills appear in activate_skill for instruction loading
  skill_tool = if all_skills != [], do: [activate_skill_tool(all_skills)], else: []

  handler_tools ++ activated_tools ++ skill_tool ++ agent_tools ++ builtins
end

defp skill_to_tool(skill) do
  %ToolDefinition{
    name: skill_short_name(skill.name),
    description: skill.description,
    input_schema: %{"type" => "object"}
  }
end
```

The tool list is rebuilt each turn. After activation, the next LLM call includes the new tool.

#### Classifier changes

The classifier routes activated module-backed tool calls to the skill's handler:

```elixir
def classifier(kits, activated_skills) do
  module_skill_map =
    activated_skills
    |> Map.new(&{skill_short_name(&1.name), &1})

  fn %{name: name} ->
    cond do
      name == "activate_skill" -> :activate_skill
      MapSet.member?(@subagent_builtins, name) -> :builtin
      MapSet.member?(agent_names, name) -> :subagent
      Map.has_key?(module_skill_map, name) -> {:module_skill, module_skill_map[name]}
      true -> :handler
    end
  end
end
```

#### Server dispatch

```elixir
defp execute_tool_calls(tool_calls, state, classifier) do
  Enum.map_reduce(tool_calls, state, fn tc, acc ->
    {result, acc} =
      case classifier.(tc) do
        :handler -> {execute_command(tc, acc), acc}
        {:module_skill, skill} -> {execute_module_skill(tc, skill, acc), acc}
        :activate_skill -> activate_skill(tc, acc)
        :subagent -> spawn_subagent(tc, acc)
        :builtin -> handle_builtin(tc, acc)
      end
    {result, acc}
  end)
end

defp execute_module_skill(%Message.ToolCall{id: id, input: input}, skill, state) do
  source_config = Map.get(skill.metadata, "source_config", [])
  context =
    %{cwd: state.definition.workspace, scope: state.scope, agent_name: state.agent_name}
    |> Map.merge(Map.new(source_config))

  execution = %Execution{skill: skill, input: input, context: context}

  case skill.handler.execute(execution) do
    {:ok, result} ->
      %Message.ToolResult{tool_call_id: id, content: to_string(result)}
    {:error, reason} ->
      %Message.ToolResult{tool_call_id: id, content: inspect(reason), is_error: true}
  end
end
```

This bypasses the `Execution` pipeline in v1 (no hooks for module-backed skills). Hooks can be added later by routing through `Handler.run/4`.

#### Full lifecycle

1. Host app adds `{SkillKit.Scheduler, oban: MyApp.Oban}` to `:sources` config
2. Kit's `load_kits/1` reads `skills/*.skill.md` at compile time, builds `%Skill{}` structs with `handler: SkillKit.Scheduler`, stores `oban: MyApp.Oban` in `skill.metadata["source_config"]`
3. Registry loads kit, registers skills
4. `ToolBuilder.build_tools/2` builds tool list — module-backed skills appear only in `activate_skill` enum, not as tools yet
5. Agent activates `scheduler:schedule` → body injected, skill added to `activated_skills` state
6. Next LLM turn: `build_tools/2` called with `activated_skills`, `schedule` tool now in tool list
7. LLM emits tool call: `{"tool": "schedule", "input": {"schedule": "0 0 * * *", "prompt": "run nightly cleanup"}}`
8. Classifier returns `{:module_skill, skill}`
9. `execute_module_skill/3` builds `%Execution{}` with source config merged into context, calls `SkillKit.Scheduler.execute(execution)`

### 4. `Code.ensure_loaded?/1` gate

In `ToolBuilder.build_tools/2`, filter activated skills before building tool definitions:

```elixir
activated_tools =
  activated_skills
  |> Enum.filter(&Code.ensure_loaded?(&1.handler))
  |> Enum.map(&skill_to_tool/1)
```

The gate lives in ToolBuilder (not Backend loading) because:
- Backend loading stays pure — it builds kits from what's declared
- ToolBuilder decides tool visibility — it already filters and classifies
- Skills remain in the registry even if their handler can't load (useful for introspection)

If the host app doesn't have Oban, `SkillKit.Scheduler` won't compile, `Code.ensure_loaded?/1` returns false, and the skills are silently excluded from the LLM's tool list and `activate_skill` enum.

### 5. `SkillKit.Scheduler` — first consumer

#### File structure

```
lib/skill_kit/scheduler/
  scheduler.ex
  worker.ex
  skills/
    schedule.skill.md
    cancel.skill.md
```

#### scheduler.ex

```elixir
defmodule SkillKit.Scheduler do
  use SkillKit.Kit

  alias SkillKit.Execution

  def execute(%Execution{skill: %{name: "scheduler:schedule"}, input: input, context: context}) do
    oban = context[:oban] || Oban
    agent = context[:agent_name]

    %{agent: agent, prompt: input["prompt"]}
    |> SkillKit.Scheduler.Worker.new(schedule_opts(input["schedule"]))
    |> Oban.insert(oban)
    |> format_result()
  end

  def execute(%Execution{skill: %{name: "scheduler:cancel"}, input: input, context: context}) do
    oban = context[:oban] || Oban

    case Oban.cancel_job(oban, input["job_id"]) do
      :ok -> {:ok, "Job #{input["job_id"]} cancelled"}
      error -> error
    end
  end

  defp schedule_opts(schedule) do
    # Parse "in 2 hours" → [schedule_in: 7200]
    # Parse "0 0 * * *" → [scheduled_at: next_occurrence(schedule)]
  end

  defp format_result({:ok, %Oban.Job{id: id}}), do: {:ok, "Scheduled — job #{id}"}
  defp format_result(error), do: error
end
```

#### worker.ex

```elixir
defmodule SkillKit.Scheduler.Worker do
  use Oban.Worker, queue: :skill_kit

  @impl true
  def perform(%Oban.Job{args: %{"agent" => agent, "prompt" => prompt} = args}) do
    result = SkillKit.start_agent(agent, prompt)

    # Re-enqueue for recurring schedules
    if cron = args["cron"] do
      next_at = next_occurrence(cron)
      args |> new(scheduled_at: next_at) |> Oban.insert()
    end

    result
  end
end
```

#### skills/schedule.skill.md

```markdown
---
name: schedule
description: Schedule a task to run later or on a recurring basis
---
Use the `schedule` tool to schedule tasks.

Provide:
- `schedule` — when to run: a cron expression (e.g. "0 0 * * *") or delay (e.g. "in 2 hours")
- `prompt` — the task to perform

Examples:
- {"schedule": "in 2 hours", "prompt": "summarize today's logs"}
- {"schedule": "0 0 * * *", "prompt": "run nightly cleanup"}
```

#### skills/cancel.skill.md

```markdown
---
name: cancel
description: Cancel a previously scheduled job
---
Use the `cancel` tool to cancel a previously scheduled job by its ID.

Provide a JSON object with:
- `job_id` — the integer job ID to cancel
```

#### Config

```elixir
config :skill_kit, :sources, [
  {SkillKit.Backend.Filesystem, path: "priv/kits"},
  {SkillKit.Scheduler, oban: MyApp.Oban}
]
```

## Implementation order

1. **Handler interface** — `command` → `input`, `execute/2` → `execute/1` taking `Execution` struct, across pipeline
2. **`use SkillKit.Kit`** — compile-time `.skill.md` loading, Backend implementation, handler wiring
3. **Activation flow** — `activated_skills` state, `activate_skill` tracks module-backed skills, tool list rebuilt per turn
4. **Dispatch path** — ToolBuilder accepts `activated_skills`, classifier `:module_skill` category, Server dispatch
5. **`Code.ensure_loaded?/1` gate** — in ToolBuilder
6. **`SkillKit.Scheduler`** — Kit + Worker + skill files (Oban optional dep)
7. **Tests** — unit tests for each layer, integration test with Oban sandbox

## What doesn't change

- `.skill.md` format (no new frontmatter fields)
- `activate_skill` flow (module-backed skills use it too)
- Backend behaviour contract
- Kit struct shape
- Registry
- Hook lifecycle (beyond map-based rewrite values)
