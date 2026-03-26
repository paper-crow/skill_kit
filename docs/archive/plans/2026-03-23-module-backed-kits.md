# Module-Backed Kits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable Elixir modules to serve as skill handlers, allowing skills to call into the host app's BEAM (Oban, Ecto, PubSub, etc.) instead of being limited to shell commands.

**Architecture:** The handler interface changes from `execute(command, context)` to `execute(execution)` where `execution` is the full `%Execution{}` struct. A new `use SkillKit.Kit` macro lets modules load companion `.skill.md` files at compile time and handle their execution. Module-backed skills go through `activate_skill` like all skills, but activation also adds their tool to the tool list dynamically. The scheduler is the first consumer.

**Tech Stack:** Elixir macros, `@external_resource`, Oban (optional dep)

**Spec:** `docs/superpowers/specs/2026-03-23-module-backed-kits-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/skill_kit/handler/behaviour.ex` | Modify | `execute/1`, `resume/3` callbacks |
| `lib/skill_kit/handler/shell.ex` | Modify | Destructure `%Execution{}` |
| `lib/skill_kit/execution.ex` | Modify | `command` → `input`, remove `build_execute_context`, update `walk_steps` |
| `lib/skill_kit/handler/handler.ex` | Modify | `command` → `input` in public API |
| `lib/skill_kit/agent/server.ex` | Modify | Remove unwrap, add `activated_skills`, dispatch `module_skill` |
| `lib/skill_kit/agent/tool_builder.ex` | Modify | Accept `activated_skills`, partition skills, `Code.ensure_loaded?` gate |
| `lib/skill_kit/kit.ex` | Modify | Add `use SkillKit.Kit` macro (or new file) |
| `test/skill_kit/execution_test.exs` | Modify | Update for `input` + `execute/1` |
| `test/skill_kit/handler_test.exs` | Modify | Update for `input` + `execute/1` |
| `test/skill_kit/handler/shell_test.exs` | Modify (if exists) | Update for `%Execution{}` arg |
| `test/skill_kit/agent/server_test.exs` | Modify | Add module-backed skill activation + dispatch tests |
| `test/skill_kit/agent/tool_builder_test.exs` | Modify | Add `activated_skills` + `skill_to_tool` tests |
| `test/skill_kit/kit_test.exs` | Modify | Add `use SkillKit.Kit` compile-time loading tests |

---

### Task 1: Handler Behaviour — `execute/1` with `Execution` struct

**Files:**
- Modify: `lib/skill_kit/handler/behaviour.ex`
- Test: `test/skill_kit/handler/shell_test.exs` (check if exists, otherwise inline in handler_test)

- [ ] **Step 1: Write failing test for new Shell execute/1 signature**

In the Shell test file, add a test that calls `Shell.execute/1` with an `%Execution{}` struct:

```elixir
test "execute/1 accepts Execution struct" do
  exec = %Execution{
    skill: nil,
    input: %{"command" => "echo hello"},
    context: %{}
  }

  assert {:ok, "hello\n"} = Shell.execute(exec)
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/handler/shell_test.exs --seed 0 -v` (or wherever the shell tests live)
Expected: FAIL — `execute/1` doesn't exist yet

- [ ] **Step 3: Update Tool callbacks**

In `lib/skill_kit/handler/behaviour.ex`, change the callbacks:

```elixir
@callback execute(execution :: SkillKit.Execution.t()) ::
            {:ok, any()} | {:error, any()} | {:pending, any()}

@callback resume(execution :: SkillKit.Execution.t(), state :: any(), decision :: :approved | {:denied, any()}) ::
            {:ok, any()} | {:error, any()} | {:pending, any()}
```

- [ ] **Step 4: Update Shell handler to destructure Execution**

In `lib/skill_kit/handler/shell.ex`, change `execute/2` to `execute/1`:

```elixir
def execute(%SkillKit.Execution{input: %{"command" => command}, context: context}) do
  opts = [:binary, :exit_status, :stderr_to_stdout] ++ port_opts(context)
  # ... rest unchanged
end
```

Update `resume` similarly:

```elixir
def resume(%SkillKit.Execution{} = exec, _state, :approved) do
  execute(exec)
end

def resume(_exec, _state, {:denied, reason}) do
  {:error, {:denied, reason}}
end
```

Update `definition/0` — no changes needed (it's independent).

- [ ] **Step 4b: Update PendingHandler test helpers**

Both `test/skill_kit/execution_test.exs` and `test/skill_kit/handler_test.exs` define `PendingHandler` modules with the old `execute/2` and `resume/3` signatures. Update them to `execute/1` and `resume/3` (with `Execution` as first arg).

- [ ] **Step 4c: Add test for resume with new signature**

```elixir
test "resume/3 delegates to execute/1" do
  exec = %Execution{
    skill: nil,
    input: %{"command" => "echo resumed"},
    context: %{}
  }

  assert {:ok, "resumed\n"} = Shell.resume(exec, %{}, :approved)
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/skill_kit/handler/shell_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/handler/behaviour.ex lib/skill_kit/handler/shell.ex test/
git commit -m "refactor: handler takes Execution struct — execute/1, resume/3"
```

---

### Task 2: Execution struct — `command` → `input`

**Files:**
- Modify: `lib/skill_kit/execution.ex`
- Test: `test/skill_kit/execution_test.exs`

- [ ] **Step 1: Update test helper and assertions to use `input`**

In `test/skill_kit/execution_test.exs`, update all `Execution.new(s, "echo hello", %{})` calls to `Execution.new(s, %{"command" => "echo hello"}, %{})`. Update any assertions that reference `exec.command` to use `exec.input`. Also update hook context assertions — any `ctx.command` references become `ctx.input` (now a map, e.g., `%{"command" => "echo hello"}`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/skill_kit/execution_test.exs --seed 0 -v`
Expected: FAIL — `command` field still exists, `new/4` still expects string

- [ ] **Step 3: Rename `command` to `input` in Execution struct**

In `lib/skill_kit/execution.ex`:

1. Change struct field `:command` → `:input` (line 50)
2. Change typespec `command: String.t()` → `input: map()` (line 39)
3. In `new/4`: rename param `command` → `input`, set `input: input` (lines 70, 99)
4. Rename `update_command/2` → `update_input/2` (line 209)
5. In `apply_step_result` where `{:allow, new_cmd}` is handled, call `update_input` (line 161)
6. In `build_pre_context`, change `:command` key to `:input` (lines 228, 237)
7. In `walk_steps` for `:execute`, change to `handler_mod.execute(exec)` (line 188) — remove `build_execute_context` call
8. In `resume/2` for `:execute`, change to `handler_mod.resume(exec, exec.suspended_state, decision)` (line 137) — remove `build_execute_context` call
9. Remove `build_execute_context/1` entirely (lines 242-244)

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/skill_kit/execution_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/execution.ex test/skill_kit/execution_test.exs
git commit -m "refactor: Execution.command → input, pass struct to handlers"
```

---

### Task 3: Handler public API — `command` → `input`

**Files:**
- Modify: `lib/skill_kit/handler/handler.ex`
- Test: `test/skill_kit/handler_test.exs`

- [ ] **Step 1: Update tests to pass maps instead of strings**

In `test/skill_kit/handler_test.exs`, change all `Handler.run(registry, skill(), "echo hello", %{})` calls to `Handler.run(registry, skill(), %{"command" => "echo hello"}, %{})`. Same for `Handler.run/3` calls.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/skill_kit/handler_test.exs --seed 0 -v`
Expected: FAIL

- [ ] **Step 3: Rename `command` to `input` in Handler module**

In `lib/skill_kit/handler/handler.ex`:

1. `run/3`: rename param `command` → `input`, pass to `Execution.new(nil, input, context, ...)`
2. `run/4`: rename param `command` → `input`, pass to `Execution.new(skill, input, context, ...)`
3. Update `@doc` strings

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/skill_kit/handler_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/handler/handler.ex test/skill_kit/handler_test.exs
git commit -m "refactor: Handler.run command → input"
```

---

### Task 4: Agent.Server — remove command unwrap

**Files:**
- Modify: `lib/skill_kit/agent/server.ex:286-287`
- Test: `test/skill_kit/agent/server_test.exs`

- [ ] **Step 1: Remove the unwrap in execute_command**

In `lib/skill_kit/agent/server.ex`, line 287, change:

```elixir
# Before
command = Map.get(input, "command", "")
context = %{cwd: state.definition.workspace, scope: state.scope}
skill_registry = {:via, Registry, {state.registry, {state.agent_name, :skill_registry}}}

case SkillKit.Tool.Runner.run(skill_registry, command, context) do
```

To:

```elixir
# After
context = %{cwd: state.definition.workspace, scope: state.scope}
skill_registry = {:via, Registry, {state.registry, {state.agent_name, :skill_registry}}}

case SkillKit.Tool.Runner.run(skill_registry, input, context) do
```

- [ ] **Step 2: Run the full test suite**

Run: `mix test --seed 0`
Expected: PASS — existing tests should still work since Shell now destructures `%{"command" => ...}` from the Execution struct

- [ ] **Step 3: Commit**

```bash
git add lib/skill_kit/agent/server.ex
git commit -m "refactor: remove command unwrap in Server.execute_command"
```

---

### Task 5: `use SkillKit.Kit` macro — compile-time skill loading

**Files:**
- Create: `lib/skill_kit/kit/macros.ex` (or add `__using__/1` to `lib/skill_kit/kit.ex`)
- Test: `test/skill_kit/kit_test.exs`
- Create: `test/support/fixtures/test_kit/skills/greet.skill.md` (test fixture)

- [ ] **Step 1: Create a test fixture skill file**

Create `test/support/fixtures/test_kit/skills/greet.skill.md`:

```markdown
---
name: greet
description: Greet a user
---
Use the `greet` tool to greet someone. Provide {"name": "the person's name"}.
```

- [ ] **Step 2: Write failing test for use SkillKit.Kit**

In `test/skill_kit/kit_test.exs`, add:

```elixir
defmodule SkillKit.KitTest.TestKit do
  use SkillKit.Kit,
    skills_dir: Path.join(__DIR__, "../support/fixtures/test_kit/skills")

  alias SkillKit.Execution

  def execute(%Execution{skill: %{name: "test_kit:greet"}, input: input}) do
    {:ok, "Hello, #{input["name"]}!"}
  end
end

describe "use SkillKit.Kit" do
  test "load_kits/1 returns kit with skills from skills/ directory" do
    assert {:ok, [kit]} = SkillKit.KitTest.TestKit.load_kits([])
    assert kit.name == "test_kit"
    assert length(kit.skills) == 1

    [skill] = kit.skills
    assert skill.name == "test_kit:greet"
    assert skill.description == "Greet a user"
    assert skill.handler == SkillKit.KitTest.TestKit
    assert skill.body =~ "greet tool"
  end

  test "source config is stored in skill metadata" do
    assert {:ok, [kit]} = SkillKit.KitTest.TestKit.load_kits(foo: :bar)
    [skill] = kit.skills
    assert skill.metadata["source_config"] == [foo: :bar]
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/skill_kit/kit_test.exs --seed 0 -v`
Expected: FAIL — `use SkillKit.Kit` not defined

- [ ] **Step 4: Implement `use SkillKit.Kit`**

In `lib/skill_kit/kit.ex`, add a `__using__/1` macro:

```elixir
defmacro __using__(opts) do
  quote do
    @behaviour SkillKit.Backend
    @behaviour SkillKit.Tool

    @kit_opts unquote(opts)

    @impl SkillKit.Backend
    def load_kits(config) do
      skills_dir = SkillKit.Kit.__resolve_skills_dir__(@kit_opts, __ENV__)
      kit_name = SkillKit.Kit.__infer_name__(__MODULE__, @kit_opts)

      skills =
        skills_dir
        |> Path.join("*.skill.md")
        |> Path.wildcard()
        |> Enum.map(fn path ->
          # Use parse_frontmatter + build skill manually to avoid
          # Parser.load_file's namespace validation (kit skills have
          # bare names like "schedule", not "namespace:schedule")
          {:ok, frontmatter, body} = SkillKit.Backend.Filesystem.Parser.parse_file(path)
          name = Map.fetch!(frontmatter, "name")

          %SkillKit.Skill{
            name: "#{kit_name}:#{name}",
            namespace: kit_name,
            description: Map.get(frontmatter, "description"),
            body: body,
            location: path,
            handler: __MODULE__,
            metadata: Map.put(%{}, "source_config", config)
          }
        end)

      {:ok, [%SkillKit.Kit{name: kit_name, skills: skills}]}
    end

    @impl SkillKit.Tool
    def definition do
      %SkillKit.Tool.Definition{
        name: "kit",
        description: "Module-backed kit handler",
        input_schema: %{"type" => "object"}
      }
    end

    @impl SkillKit.Tool
    def resume(_exec, _state, {:denied, reason}), do: {:error, {:denied, reason}}
    def resume(_exec, _state, _decision), do: {:error, :not_resumable}

    defoverridable [resume: 3, definition: 0]
  end
end
```

Add helper functions (not macros) at module level:

```elixir
def __resolve_skills_dir__(opts, env) do
  case Keyword.get(opts, :skills_dir) do
    nil ->
      env.file
      |> Path.dirname()
      |> Path.join("skills")
    dir ->
      dir
  end
end

def __infer_name__(module, opts) do
  Keyword.get_lazy(opts, :name, fn ->
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end)
end
```

Register `@external_resource` for each skill file for recompilation tracking. This needs to be done at compile time — use `@before_compile` or `Module.register_attribute` with `@external_resource` in the `load_kits` function won't work since it runs at runtime. For v1, skip `@external_resource` — the compile-time loading happens in `load_kits/1` which is called at runtime by the Registry. Add `@external_resource` support in a follow-up.

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/skill_kit/kit_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/kit.ex test/skill_kit/kit_test.exs test/support/fixtures/
git commit -m "feat: use SkillKit.Kit macro — compile-time skill loading"
```

---

### Task 6: ToolBuilder — `activated_skills` and `skill_to_tool`

**Files:**
- Modify: `lib/skill_kit/agent/tool_builder.ex`
- Test: `test/skill_kit/agent/tool_builder_test.exs`

- [ ] **Step 1: Write failing test for activated_skills in build_tools**

```elixir
test "activated module-backed skills appear as individual tools" do
  module_skill = %Skill{
    name: "scheduler:schedule",
    namespace: "scheduler",
    description: "Schedule a task",
    body: "Use schedule tool",
    handler: SomeFakeModule
  }

  tools = ToolBuilder.build_tools([], activated_skills: [module_skill])

  tool_names = Enum.map(tools, & &1.name)
  assert "schedule" in tool_names
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/agent/tool_builder_test.exs --seed 0 -v`
Expected: FAIL — `activated_skills` option not recognized

- [ ] **Step 3: Implement activated_skills support in build_tools**

In `lib/skill_kit/agent/tool_builder.ex`, update `build_tools/2`:

```elixir
def build_tools(kits, opts \\ []) do
  handlers = Keyword.get(opts, :handlers, [SkillKit.Tools.Shell])
  subagent = Keyword.get(opts, :subagent, false)
  activated_skills = Keyword.get(opts, :activated_skills, [])

  all_skills = Enum.flat_map(kits, & &1.skills)
  all_agents = Enum.flat_map(kits, & &1.agents)

  handler_tools = Enum.map(handlers, & &1.definition())

  activated_tools =
    activated_skills
    |> Enum.filter(&Code.ensure_loaded?(&1.handler))
    |> Enum.map(&skill_to_tool/1)

  # Filter unloadable module-backed skills from activate_skill enum too
  visible_skills =
    Enum.filter(all_skills, fn skill ->
      skill.handler == SkillKit.Tools.Shell or Code.ensure_loaded?(skill.handler)
    end)

  skill_tool = if visible_skills != [], do: [activate_skill_tool(visible_skills)], else: []
  agent_tools = Enum.map(all_agents, &agent_to_tool/1)
  builtins = if subagent, do: builtin_tools(), else: []

  handler_tools ++ activated_tools ++ skill_tool ++ agent_tools ++ builtins
end
```

Add `skill_to_tool/1` and `skill_short_name/1`:

```elixir
defp skill_to_tool(skill) do
  %ToolDefinition{
    name: skill_short_name(skill.name),
    description: skill.description,
    input_schema: %{"type" => "object"}
  }
end

defp skill_short_name(name) do
  case String.split(name, ":", parts: 2) do
    [_ns, short] -> short
    [short] -> short
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/agent/tool_builder_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 5: Write test for Code.ensure_loaded? gate**

```elixir
test "activated skills with unloadable handlers are excluded" do
  bad_skill = %Skill{
    name: "broken:thing",
    namespace: "broken",
    description: "Won't load",
    body: "nope",
    handler: DoesNotExist.Module
  }

  tools = ToolBuilder.build_tools([], activated_skills: [bad_skill])

  tool_names = Enum.map(tools, & &1.name)
  refute "thing" in tool_names
end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/skill_kit/agent/tool_builder_test.exs --seed 0 -v`
Expected: PASS (gate already implemented in step 3)

- [ ] **Step 7: Commit**

```bash
git add lib/skill_kit/agent/tool_builder.ex test/skill_kit/agent/tool_builder_test.exs
git commit -m "feat: ToolBuilder supports activated_skills with Code.ensure_loaded? gate"
```

---

### Task 7: Classifier — `:module_skill` category

**Files:**
- Modify: `lib/skill_kit/agent/tool_builder.ex`
- Test: `test/skill_kit/agent/tool_builder_test.exs`

- [ ] **Step 1: Write failing test for module_skill classification**

```elixir
test "classifier returns {:module_skill, skill} for activated module-backed skills" do
  module_skill = %Skill{
    name: "scheduler:schedule",
    namespace: "scheduler",
    description: "Schedule a task",
    body: "Use schedule tool",
    handler: SomeFakeModule
  }

  classify = ToolBuilder.classifier([], [module_skill])
  assert {:module_skill, ^module_skill} = classify.(%{name: "schedule"})
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/agent/tool_builder_test.exs --seed 0 -v`
Expected: FAIL — `classifier/2` doesn't exist (only `classifier/1`)

- [ ] **Step 3: Update classifier to accept activated_skills**

In `lib/skill_kit/agent/tool_builder.ex`, change `classifier/1` to `classifier/2`:

```elixir
def classifier(kits, activated_skills \\ []) do
  agent_names =
    kits
    |> Enum.flat_map(& &1.agents)
    |> MapSet.new(& &1.name)

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

- [ ] **Step 4: Update existing classifier call sites**

In `lib/skill_kit/agent/server.ex`, the call at `handle_response/2` passes kits only: `ToolBuilder.classifier(state.kits)`. Update to include activated_skills:

```elixir
classifier = ToolBuilder.classifier(state.kits, Map.get(state, :activated_skills, []))
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/skill_kit/agent/tool_builder_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/agent/tool_builder.ex lib/skill_kit/agent/server.ex test/skill_kit/agent/tool_builder_test.exs
git commit -m "feat: classifier supports :module_skill category for activated skills"
```

---

### Task 8: Server — `activated_skills` state + activation tracking

**Files:**
- Modify: `lib/skill_kit/agent/server.ex`
- Test: `test/skill_kit/agent/server_test.exs`

- [ ] **Step 1: Add `activated_skills` to server state**

In `lib/skill_kit/agent/server.ex`, add to the struct (after line 32):

```elixir
activated_skills: []
```

And to the typespec (after line 50):

```elixir
activated_skills: [SkillKit.Skill.t()]
```

- [ ] **Step 2: Update `activate_skill` to track module-backed skills**

In `lib/skill_kit/agent/server.ex`, the current `activate_skill/2` (around line 326) returns `{result, state}` — but currently it only returns a result (no state update). It needs to return `{result, updated_state}` for module-backed skills.

Check the current return — `activate_skill` returns just `%Message.ToolResult{}`, not a tuple. The `execute_tool_calls` dispatch at line 275 does:

```elixir
:activate_skill -> {activate_skill(tc, acc), acc}
```

This means `activate_skill` returns only the result, and state (`acc`) is passed through unchanged. To track activated skills, change to return `{result, state}`:

```elixir
:activate_skill -> activate_skill(tc, acc)
```

Then update `activate_skill/2` to return a tuple:

```elixir
defp activate_skill(%Message.ToolCall{id: id, input: input}, state) do
  skill_name = Map.get(input, "name", "")
  skill_registry = {:via, Registry, {state.registry, {state.agent_name, :skill_registry}}}

  opts = if state.scope, do: [scopes: state.scope], else: []

  case SkillKit.Catalog.activate(skill_registry, skill_name, %{}, opts) do
    {:ok, rendered_body} ->
      # Find the skill struct to check if it's module-backed
      skill = find_skill_by_name(skill_name, state)

      already_activated = Enum.any?(state.activated_skills, &(&1.name == skill_name))

      state =
        if skill && skill.handler != SkillKit.Tools.Shell && !already_activated do
          %{state | activated_skills: [skill | state.activated_skills]}
        else
          state
        end

      {%Message.ToolResult{tool_call_id: id, content: rendered_body}, state}

    {:error, :unauthorized} ->
      {%Message.ToolResult{
        tool_call_id: id,
        content: "Unauthorized: insufficient scope for skill #{skill_name}",
        is_error: true
      }, state}

    {:error, reason} ->
      {%Message.ToolResult{
        tool_call_id: id,
        content: "Error: #{inspect(reason)}",
        is_error: true
      }, state}
  end
end
```

Add helper to find skill by name from kits:

```elixir
defp find_skill_by_name(name, state) do
  state.kits
  |> Enum.flat_map(& &1.skills)
  |> Enum.find(&(&1.name == name))
end
```

- [ ] **Step 3: Update `run_agent_loop` to pass `activated_skills` to `build_tools`**

In `lib/skill_kit/agent/server.ex`, line 205:

```elixir
# Before
tools = ToolBuilder.build_tools(state.kits, subagent: state.depth > 0)

# After
tools = ToolBuilder.build_tools(state.kits,
  subagent: state.depth > 0,
  activated_skills: state.activated_skills
)
```

- [ ] **Step 4: Run full test suite**

Run: `mix test --seed 0`
Expected: PASS — existing tests unaffected (no module-backed skills in current tests)

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/agent/server.ex
git commit -m "feat: Server tracks activated_skills, rebuilds tool list per turn"
```

---

### Task 9: Server — `execute_module_skill` dispatch

**Files:**
- Modify: `lib/skill_kit/agent/server.ex`
- Test: `test/skill_kit/agent/server_test.exs`

- [ ] **Step 1: Add `execute_module_skill` to dispatch**

In `lib/skill_kit/agent/server.ex`, update the `execute_tool_calls` dispatch (around line 274):

```elixir
case classifier.(tc) do
  :handler -> {execute_command(tc, acc), acc}
  {:module_skill, skill} -> {execute_module_skill(tc, skill, acc), acc}
  :activate_skill -> activate_skill(tc, acc)
  :subagent -> spawn_subagent(tc, acc)
  :builtin -> handle_builtin(tc, acc)
end
```

- [ ] **Step 2: Implement `execute_module_skill/3`**

Add to `lib/skill_kit/agent/server.ex`:

```elixir
defp execute_module_skill(%Message.ToolCall{id: id, input: input}, skill, state) do
  source_config = Map.get(skill.metadata, "source_config", [])

  context =
    %{cwd: state.definition.workspace, scope: state.scope, agent_name: state.agent_name}
    |> Map.merge(Map.new(source_config))

  # Note: add `alias SkillKit.Execution` at the module level in Server, not here
  execution = %SkillKit.Execution{skill: skill, input: input, context: context}

  case skill.handler.execute(execution) do
    {:ok, result} ->
      %Message.ToolResult{tool_call_id: id, content: to_string(result)}

    {:error, reason} ->
      %Message.ToolResult{tool_call_id: id, content: inspect(reason), is_error: true}
  end
end
```

- [ ] **Step 3: Run full test suite**

Run: `mix test --seed 0`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add lib/skill_kit/agent/server.ex
git commit -m "feat: Server dispatches module_skill to skill handler"
```

---

### Task 10: Integration test — full module-backed skill lifecycle

**Files:**
- Create: `test/skill_kit/kit/module_backed_test.exs`
- Create: `test/support/fixtures/test_kit/test_kit.ex` (test Kit module)

- [ ] **Step 1: Create test Kit module with execute/1**

Create a test kit module that can be used in integration tests:

```elixir
defmodule SkillKit.Test.EchoKit do
  use SkillKit.Kit,
    skills_dir: Path.join(__DIR__, "../fixtures/test_kit/skills")

  alias SkillKit.Execution

  def execute(%Execution{skill: %{name: "test_kit:greet"}, input: input}) do
    {:ok, "Hello, #{input["name"]}!"}
  end
end
```

- [ ] **Step 2: Write integration test**

```elixir
test "module-backed skill loads, activates, and executes" do
  # 1. Load kit
  {:ok, [kit]} = SkillKit.Test.EchoKit.load_kits([])
  assert [skill] = kit.skills
  assert skill.handler == SkillKit.Test.EchoKit

  # 2. Skill appears in activate_skill enum
  tools = ToolBuilder.build_tools([kit])
  activate_tool = Enum.find(tools, &(&1.name == "activate_skill"))
  assert "test_kit:greet" in activate_tool.input_schema["properties"]["name"]["enum"]

  # 3. No greet tool before activation
  tool_names = Enum.map(tools, & &1.name)
  refute "greet" in tool_names

  # 4. After activation, greet tool appears
  tools_after = ToolBuilder.build_tools([kit], activated_skills: [skill])
  tool_names_after = Enum.map(tools_after, & &1.name)
  assert "greet" in tool_names_after

  # 5. Classifier routes correctly
  classify = ToolBuilder.classifier([kit], [skill])
  assert {:module_skill, ^skill} = classify.(%{name: "greet"})

  # 6. Execute works
  execution = %Execution{
    skill: skill,
    input: %{"name" => "World"},
    context: %{}
  }
  assert {:ok, "Hello, World!"} = SkillKit.Test.EchoKit.execute(execution)
end
```

- [ ] **Step 3: Run test to verify it passes**

Run: `mix test test/skill_kit/kit/module_backed_test.exs --seed 0 -v`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add test/
git commit -m "test: integration test for full module-backed skill lifecycle"
```

---

### Task 11: `SkillKit.Scheduler` — first consumer (Oban optional dep)

This task is deferred until the core infrastructure (Tasks 1-10) is complete and passing. It requires adding Oban as an optional dependency and creating the scheduler Kit with companion skill files. The spec section 5 has the full implementation details.

**Files:**
- Create: `lib/skill_kit/scheduler/scheduler.ex`
- Create: `lib/skill_kit/scheduler/worker.ex`
- Create: `lib/skill_kit/scheduler/skills/schedule.skill.md`
- Create: `lib/skill_kit/scheduler/skills/cancel.skill.md`
- Modify: `mix.exs` (add `oban` as optional dep)

This task will be planned separately once the infrastructure is verified.

---

## Run Order

Tasks 1-4 are sequential — each builds on the previous (handler interface → execution struct → public API → server unwrap).

Tasks 5-7 can be worked in parallel after Task 4 (Kit macro, ToolBuilder, Classifier are independent).

Tasks 8-9 depend on Tasks 5-7 (server state + dispatch needs Kit, ToolBuilder, and Classifier).

Task 10 is the integration test after everything is in place.

Task 11 is deferred.
