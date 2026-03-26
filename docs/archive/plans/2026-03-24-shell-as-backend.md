# Shell as Backend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Register `SkillKit.Tools.Shell` through the `skills:` mechanism like any other Backend/Kit, removing hardcoded Shell defaults from ToolBuilder and Handler.

**Architecture:** `SkillKit.Tools.Shell` implements `Backend` (returning a kit with the bash tool and handler config in metadata). ToolBuilder discovers handler tools from kits instead of a hardcoded list. `Tool.Runner.run/3` receives the handler module explicitly instead of reading app config. Shell's cwd/env config flows through kit metadata to the pipeline context.

**Tech Stack:** Elixir, SkillKit

---

## File Structure

| Action | File | Change |
|--------|------|--------|
| Modify | `lib/skill_kit/shell.ex` | Add `@behaviour SkillKit.Backend`, implement `load_kits/1` |
| Modify | `lib/skill_kit/agent/tool_builder.ex` | Remove hardcoded `:handlers` default, discover from kits |
| Modify | `lib/skill_kit/handler/handler.ex` | `run/3` accepts handler module as parameter |
| Modify | `lib/skill_kit/agent/server.ex` | Pass handler from kits to Tool.Runner.run, merge handler config into context |
| Modify | `lib/skill_kit/agent/agent.ex` | Remove handler config default |
| Modify | `lib/mix/tasks/skill_kit.chat.ex` | Add `{SkillKit.Tools.Shell, []}` to skills |
| Modify | `lib/mix/tasks/skill_kit.demo.ex` | Add `{SkillKit.Tools.Shell, []}` to skills |
| Modify | `examples/persona_chat/lib/persona_chat/cli.ex` | Add `{SkillKit.Tools.Shell, []}` to skills |
| Modify | Various test files | Add Shell to skills where agents need bash |

---

### Task 1: Make SkillKit.Tools.Shell a Kit

`SkillKit.Tools.Shell` currently implements `Tool` manually. Convert it to `use SkillKit.Kit` which gives it both `Backend` and `Tool` — the same pattern as any module-backed kit. The default `skills_dir` will point to a nonexistent `skills/` folder next to `shell.ex`, which is fine — `Path.wildcard` returns `[]` for missing directories, so the kit loads with zero file-based skills.

Shell overrides `execute/1`, `definition/0`, and `resume/3` (all already implemented). The macro generates `load_kits/1` automatically.

However, Shell needs to pass its config (cwd, env) through the kit. The macro's generated `load_kits/1` calls `Kit.do_load_kits` which doesn't carry config metadata. We need to **override `load_kits/1`** to merge the caller's config into the kit's metadata.

**Files:**
- Modify: `lib/skill_kit/shell.ex`
- Modify: `test/skill_kit/shell_test.exs`

- [ ] **Step 1: Write tests for Shell as Kit**

Add to `test/skill_kit/shell_test.exs`:

```elixir
describe "load_kits/1 (Backend)" do
  test "returns a kit named shell" do
    assert {:ok, [kit]} = SkillKit.Tools.Shell.load_kits([])
    assert kit.name == "shell"
  end

  test "stores cwd in metadata when provided" do
    assert {:ok, [kit]} = SkillKit.Tools.Shell.load_kits(cwd: "/tmp")
    assert kit.metadata.cwd == "/tmp"
  end

  test "stores env in metadata when provided" do
    assert {:ok, [kit]} = SkillKit.Tools.Shell.load_kits(env: [{"FOO", "bar"}])
    assert kit.metadata.env == [{"FOO", "bar"}]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/shell_test.exs`
Expected: Fail — `load_kits/1` doesn't exist yet.

- [ ] **Step 3: Convert Shell to use SkillKit.Kit**

Rewrite `lib/skill_kit/shell.ex`:

```elixir
defmodule SkillKit.Tools.Shell do
  @moduledoc """
  Shell handler kit — provides bash command execution.

  Registered through `skills:` like any other kit:

      SkillKit.start_agent(
        skills: [
          {SkillKit.Tools.Shell, cwd: File.cwd!()},
          {SkillKit.Backend.Filesystem, dir: ".skills"}
        ]
      )

  ## Options

    * `:cwd` — working directory for commands (default: `File.cwd!()`)
    * `:env` — list of `{key, value}` environment variables
  """

  use SkillKit.Kit, name: "shell"

  alias SkillKit.Pipeline

  # Override load_kits to merge caller config into kit metadata
  @impl SkillKit.Backend
  def load_kits(config) do
    {:ok, [kit]} = super(config)
    metadata = Map.merge(kit.metadata, config_to_metadata(config))
    {:ok, [%{kit | metadata: metadata}]}
  end

  @impl SkillKit.Tool
  def execute(%Pipeline{input: %{"command" => command}, context: context}) do
    opts = [:binary, :exit_status, :stderr_to_stdout] ++ port_opts(context)

    port =
      Port.open(
        {:spawn_executable, System.find_executable("sh")},
        [args: ["-c", command]] ++ opts
      )

    collect(port, [])
  end

  @impl SkillKit.Tool
  def definition do
    %SkillKit.Tool.Definition{
      name: "bash",
      description:
        "Execute a shell command. Use for running scripts, reading/writing files, " <>
          "fetching URLs (curl), git operations, and any system interaction. " <>
          "The working directory defaults to the current process working directory.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The shell command to execute"
          }
        },
        "required" => ["command"]
      }
    }
  end

  @impl SkillKit.Tool
  def resume(%Pipeline{} = exec, _state, :approved), do: execute(exec)
  def resume(_exec, _state, {:denied, reason}), do: {:error, {:denied, reason}}

  # --- Private ---

  defp config_to_metadata(config) do
    %{}
    |> maybe_put(:cwd, Keyword.get(config, :cwd))
    |> maybe_put(:env, Keyword.get(config, :env))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp port_opts(context) do
    []
    |> maybe_add_cd(context)
    |> maybe_add_env(context)
  end

  defp maybe_add_cd(opts, %{cwd: cwd}) when is_binary(cwd), do: [{:cd, cwd} | opts]
  defp maybe_add_cd(opts, _context), do: [{:cd, File.cwd!()} | opts]

  defp maybe_add_env(opts, %{env: env}) when is_list(env) do
    merged =
      System.get_env()
      |> Map.merge(Map.new(env))
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    [{:env, merged} | opts]
  end

  defp maybe_add_env(opts, _context), do: opts

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, [acc | data])
      {^port, {:exit_status, 0}} -> {:ok, IO.iodata_to_binary(acc)}
      {^port, {:exit_status, code}} -> {:error, {IO.iodata_to_binary(acc), code}}
    end
  end
end
```

Note: `super(config)` calls the macro-generated `load_kits/1` which loads from the (nonexistent) skills dir and returns `{:ok, [%Kit{name: "shell", skills: []}]}`. We merge our config metadata on top.

IMPORTANT: The `use SkillKit.Kit` macro generates `load_kits/1` as `defoverridable` — wait, actually it only marks `resume: 3, definition: 0` as overridable, NOT `load_kits/1`. Check the macro — if `load_kits/1` is not overridable, we need to add it to the `defoverridable` list in the Kit macro first.

Read `lib/skill_kit/kit.ex` line 79 to confirm. If `load_kits` is not overridable, add it:
```elixir
defoverridable resume: 3, definition: 0, load_kits: 1
```

- [ ] **Step 4: Run tests**

Run: `mix test test/skill_kit/shell_test.exs`
Expected: All pass.

- [ ] **Step 5: Run full test suite**

Run: `mix test`
Expected: All pass — Shell still implements the same callbacks.

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/shell.ex lib/skill_kit/kit.ex test/skill_kit/shell_test.exs
git commit -m "refactor(shell): convert to use SkillKit.Kit for uniform registration"
```
- `definition/0` → `@impl SkillKit.Tool`
- `resume/3` → `@impl SkillKit.Tool`

- [ ] **Step 4: Run tests**

Run: `mix test test/skill_kit/shell_test.exs`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/shell.ex test/skill_kit/shell_test.exs
git commit -m "feat(shell): implement Backend behaviour for kit-based registration"
```

---

### Task 2: ToolBuilder discovers handlers from kits

Currently `build_tools` has `handlers: [SkillKit.Tools.Shell]` as a default. Change it to discover handler kits from the kit list — any kit with `metadata.handler` provides a handler tool.

**Files:**
- Modify: `lib/skill_kit/agent/tool_builder.ex`
- Modify: `test/skill_kit/agent/tool_builder_test.exs`

- [ ] **Step 1: Write test for handler discovery from kits**

Add to `test/skill_kit/agent/tool_builder_test.exs`:

```elixir
test "discovers handler tools from kits with metadata.handler" do
  shell_kit = %Kit{name: "shell", metadata: %{handler: SkillKit.Tools.Shell}}
  skill_kit = %Kit{name: "my_kit", skills: [%Skill{name: "my_kit:test", description: "test", handler: SkillKit.Tools.Shell}]}
  tools = ToolBuilder.build_tools([shell_kit, skill_kit])

  tool_names = Enum.map(tools, & &1.name)
  assert "bash" in tool_names
end

test "no bash tool when Shell kit not in kits list" do
  skill_kit = %Kit{name: "my_kit", skills: [%Skill{name: "my_kit:test", description: "test", handler: SkillKit.Tools.Shell}]}
  tools = ToolBuilder.build_tools([skill_kit])

  tool_names = Enum.map(tools, & &1.name)
  refute "bash" in tool_names
end
```

- [ ] **Step 2: Run tests to verify behavior**

Run: `mix test test/skill_kit/agent/tool_builder_test.exs`
Expected: First test may pass (Shell is currently hardcoded), second will fail.

- [ ] **Step 3: Update ToolBuilder**

In `lib/skill_kit/agent/tool_builder.ex`:

Remove the `:handlers` option and default. Instead, extract handler modules from kits:

```elixir
def build_tools(kits, opts \\ []) do
  subagent = Keyword.get(opts, :subagent, false)
  activated_skills = Keyword.get(opts, :activated_skills, [])

  all_skills = Enum.flat_map(kits, & &1.skills)
  all_agents = Enum.flat_map(kits, & &1.agents)

  # Discover handler tools from kits that declare a handler in metadata
  handler_tools = discover_handler_tools(kits)

  activated_tools =
    activated_skills
    |> Enum.filter(&Code.ensure_loaded?(&1.handler))
    |> Enum.map(&skill_to_tool/1)

  # Filter visible skills — those whose handler is either a discovered handler or a loaded module
  handler_modules = MapSet.new(handler_modules_from_kits(kits))

  visible_skills =
    Enum.filter(all_skills, fn skill ->
      MapSet.member?(handler_modules, skill.handler) or Code.ensure_loaded?(skill.handler)
    end)

  skill_tool = if visible_skills != [], do: [activate_skill_tool(visible_skills)], else: []
  agent_tools = Enum.map(all_agents, &agent_to_tool/1)
  builtins = if subagent, do: builtin_tools(), else: []

  handler_tools ++ activated_tools ++ skill_tool ++ agent_tools ++ builtins
end

defp discover_handler_tools(kits) do
  kits
  |> Enum.filter(&Map.has_key?(&1.metadata, :handler))
  |> Enum.map(fn kit -> kit.metadata.handler.definition() end)
end

defp handler_modules_from_kits(kits) do
  kits
  |> Enum.filter(&Map.has_key?(&1.metadata, :handler))
  |> Enum.map(& &1.metadata.handler)
end
```

Also update the `classifier/2` — currently it checks if a tool name is NOT activate_skill, subagent, or builtin, and defaults to `:handler`. This still works since the handler routing in server.ex just calls `Tool.Runner.run`. No change needed to classifier.

- [ ] **Step 4: Update existing tests**

Many existing ToolBuilder tests construct kits without a Shell handler kit. They'll lose the bash tool. Update tests that expect bash to include a Shell kit:

```elixir
@shell_kit %Kit{name: "shell", metadata: %{handler: SkillKit.Tools.Shell}}
```

Add this kit to the kit lists in tests that expect bash tool to be present.

Tests that don't care about bash can stay as-is — they just won't have the bash tool in the list.

- [ ] **Step 5: Run tests**

Run: `mix test`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/agent/tool_builder.ex test/skill_kit/agent/tool_builder_test.exs
git commit -m "refactor(tool-builder): discover handler tools from kits instead of hardcoding"
```

---

### Task 3: Tool.Runner.run receives handler explicitly

`Tool.Runner.run/3` currently reads the handler from app config. Change it to accept the handler module as a parameter. The server is the one that knows which handler to use.

**Files:**
- Modify: `lib/skill_kit/handler/handler.ex`
- Modify: `lib/skill_kit/agent/server.ex`
- Modify: `test/skill_kit/handler_test.exs`

- [ ] **Step 1: Update Tool.Runner.run/3 to accept handler**

Change `Tool.Runner.run/3` signature from `run(registry, input, context)` to `run(handler, registry, input, context)`:

```elixir
def run(handler, registry, input, context) do
  hooks = collect_and_filter_hooks(registry, handler)

  %Pipeline{
    skill: nil,
    input: wrap_input(input),
    context: context,
    steps: build_steps(hooks, handler)
  }
  |> Pipeline.run()
end
```

Remove the `Application.get_env(:skill_kit, :handler, SkillKit.Tools.Shell)` line.

Keep `run/4` (skill-based) unchanged — it already gets the handler from `skill.handler`.

- [ ] **Step 2: Update server.ex to pass handler**

In `lib/skill_kit/agent/server.ex`, the `execute_command/2` function calls `Tool.Runner.run(skill_registry, input, context)`. It needs to find the handler module from kits and pass it:

```elixir
defp execute_command(%ToolCall{id: id, input: input}, state) do
  handler = find_handler(state.kits)
  context = build_handler_context(state)
  skill_registry = {:via, Registry, {state.registry, {state.agent_name, :skill_registry}}}

  case SkillKit.Tool.Runner.run(handler, skill_registry, input, context) do
    # ... unchanged
  end
end

defp find_handler(kits) do
  kit = Enum.find(kits, &Map.has_key?(&1.metadata, :handler))
  if kit, do: kit.metadata.handler, else: raise("No handler registered — add {SkillKit.Tools.Shell, []} to skills")
end

defp build_handler_context(state) do
  context = %{scope: state.scope}
  handler_kit = Enum.find(state.kits, &Map.has_key?(&1.metadata, :handler))

  if handler_kit do
    context
    |> maybe_merge_cwd(handler_kit.metadata)
    |> maybe_merge_env(handler_kit.metadata)
  else
    context
  end
end

defp maybe_merge_cwd(context, %{cwd: cwd}), do: Map.put(context, :cwd, cwd)
defp maybe_merge_cwd(context, _metadata), do: context

defp maybe_merge_env(context, %{env: env}), do: Map.put(context, :env, env)
defp maybe_merge_env(context, _metadata), do: context
```

Also update `execute_module_skill` which builds its own context — remove `cwd:` from there too (it was already removed in the workspace task, but verify).

- [ ] **Step 3: Update handler tests**

Tests for `Tool.Runner.run` that don't pass a handler will break. Update them to pass `SkillKit.Tools.Shell` as the first arg.

- [ ] **Step 4: Run tests**

Run: `mix test`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/handler/handler.ex lib/skill_kit/agent/server.ex test/
git commit -m "refactor(handler): receive handler module explicitly, remove app config default"
```

---

### Task 4: Add Shell to skills in callers

Now that Shell isn't hardcoded, every agent that needs bash must include `{SkillKit.Tools.Shell, []}` in its skills. Update all callers.

**Files:**
- Modify: `lib/mix/tasks/skill_kit.chat.ex`
- Modify: `lib/mix/tasks/skill_kit.demo.ex`
- Modify: `examples/persona_chat/lib/persona_chat/cli.ex`
- Modify: `lib/skill_kit/test.ex` (test helper)
- Modify: Various test files that start agents

- [ ] **Step 1: Update Mix tasks**

In `lib/mix/tasks/skill_kit.chat.ex`, add Shell to skills:

Find the `start_agent` call and add `{SkillKit.Tools.Shell, []}` to the skills list.

Same for `lib/mix/tasks/skill_kit.demo.ex`.

- [ ] **Step 2: Update example app**

In `examples/persona_chat/lib/persona_chat/cli.ex`, both `start_agent` calls need Shell:

```elixir
# Lobby
SkillKit.start_agent(
  skills: [
    {SkillKit.Backend.Filesystem, dir: ".skills"},
    {SkillKit.Tools.Shell, []}
  ],
  scope: scope
)

# Persona
SkillKit.start_agent(
  skills: [
    {SkillKit.Backend.Filesystem, dir: persona_dir},
    {SkillKit.Backend.Filesystem, dir: ".skills/memory_kit"},
    {SkillKit.Tools.Shell, []}
  ],
  ...
)
```

- [ ] **Step 3: Update test helper**

In `lib/skill_kit/test.ex`, if there's a default skills list for test agents, add `{SkillKit.Tools.Shell, []}`.

- [ ] **Step 4: Update integration tests**

Any test that starts an agent and expects bash capability needs Shell in its skills. Search for `start_agent` in tests and add Shell where bash is expected.

Loop tests and agent tests are the main ones.

- [ ] **Step 5: Run tests**

Run: `mix test`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add lib/ test/ examples/
git commit -m "refactor: register Shell explicitly in all agent skills lists"
```

---

### Task 5: Remove app config for handler

The `config :skill_kit, :handler` config key is no longer used. Clean up references.

**Files:**
- Modify: `lib/skill_kit.ex` (moduledoc)
- Modify: `lib/skill_kit/handler/handler.ex` (docs)
- Modify: `config/config.exs` (if present)

- [ ] **Step 1: Remove handler config references**

In `lib/skill_kit.ex` moduledoc, remove the handler config example:
```elixir
# Remove this:
    # Default handler
    config :skill_kit, :handler, SkillKit.Tools.Shell
```

In `lib/skill_kit/handler/handler.ex`, update docs to remove config reference.

Check `config/config.exs` and `config/test.exs` for handler config — remove if present.

- [ ] **Step 2: Run precommit**

Run: `mix precommit`
Expected: All clean.

- [ ] **Step 3: Commit**

```bash
git add lib/ config/
git commit -m "refactor: remove :handler app config, Shell registered through skills"
```
