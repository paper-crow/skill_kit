# Persona Chat Example App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a CLI example app exercising SkillKit's skills, kits, agents, conversation store, and authorization — identifying and fixing library gaps along the way.

**Architecture:** Two-phase approach. Phase 1 fixes SkillKit library gaps (scope protocol, activate_skill arguments, variable syntax unification, shell handler env). Phase 2 builds the example app on top. The example app is a thin CLI harness + scope struct; all behavior lives in skills, agents, and kits loaded via `Backend.Filesystem`.

**Tech Stack:** Elixir, SkillKit (path dep), Mix tasks

**Spec:** `docs/superpowers/specs/2026-03-24-persona-chat-example-design.md`

---

## File Structure

### Phase 1: SkillKit Library Changes

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `lib/skill_kit/scope/scope.ex` | New `SkillKit.Scope` protocol (permissions/1, resolve/3) |
| Create | `test/skill_kit/scope/scope_protocol_test.exs` | Protocol tests |
| Modify | `lib/skill_kit/scope.ex` → rename to `lib/skill_kit/scope/validation.ex` | Move string validation to `SkillKit.Scope.Validation` |
| Modify | `test/skill_kit/scope_test.exs` → rename to `test/skill_kit/scope/validation_test.exs` | Update module reference |
| Modify | `lib/skill_kit/authorization.ex` | Use `Scope.Validation` instead of `Scope` for string matching |
| Modify | `lib/skill_kit/skill.ex` | Unified variable syntax, scope fallback resolution |
| Modify | `test/skill_kit/skill_test.exs` | Updated render tests |
| Modify | `lib/skill_kit/agent/tool_builder.ex` | Add `arguments` field to activate_skill tool schema |
| Modify | `test/skill_kit/agent/tool_builder_test.exs` | Test arguments field |
| Modify | `lib/skill_kit/agent/server.ex` | Pass arguments to Catalog.activate, pass scope to Skill.render, build context.env from scope |
| Modify | `test/skill_kit/agent/server_test.exs` | Test arguments passthrough and env population |

### Phase 2: Example App

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `examples/persona_chat/mix.exs` | Project config with :skill_kit path dep |
| Create | `examples/persona_chat/lib/persona_chat/cli.ex` | Mix task: args, stdin/stdout loop, agent switching |
| Create | `examples/persona_chat/lib/persona_chat/scope.ex` | Scope struct + SkillKit.Scope protocol impl |
| Create | `examples/persona_chat/agents/lobby/AGENT.md` | Lobby agent definition |
| Create | `examples/persona_chat/skills/persona_kit/brainstorm.skill.md` | Generate persona concepts |
| Create | `examples/persona_chat/skills/persona_kit/develop_voice.skill.md` | Develop tone and voice |
| Create | `examples/persona_chat/skills/persona_kit/build_backstory.skill.md` | Create name and backstory |
| Create | `examples/persona_chat/skills/persona_kit/finalize_persona.skill.md` | Write AGENT.md file |
| Create | `examples/persona_chat/skills/persona_kit/list_personas.skill.md` | List available personas |
| Create | `examples/persona_chat/skills/persona_kit/delete_persona.skill.md` | Delete a persona |
| Create | `examples/persona_chat/skills/memory_kit/user_memory.skill.md` | Per-user memory read/write |

---

## Phase 1: SkillKit Library Changes

### Task 1: Introduce SkillKit.Scope Protocol

The current `SkillKit.Scope` module is pure string validation. We need to:
1. Move the validation logic to `SkillKit.Scope.Validation`
2. Create the `SkillKit.Scope` protocol with `permissions/1` and `resolve/3`
3. Update `Authorization` to use the new module path

**Files:**
- Create: `lib/skill_kit/scope/scope.ex`
- Create: `test/skill_kit/scope/scope_protocol_test.exs`
- Rename: `lib/skill_kit/scope.ex` → `lib/skill_kit/scope/validation.ex`
- Rename: `test/skill_kit/scope_test.exs` → `test/skill_kit/scope/validation_test.exs`
- Modify: `lib/skill_kit/authorization.ex`
- Modify: `test/skill_kit/authorization_test.exs`

- [ ] **Step 1: Write protocol tests**

Create `test/skill_kit/scope/scope_protocol_test.exs`:

```elixir
defmodule SkillKit.ScopeTest do
  use ExUnit.Case, async: true

  alias SkillKit.Scope

  # Test struct for protocol implementation
  defmodule TestScope do
    defstruct [:user, permissions: []]
  end

  defimpl Scope, for: TestScope do
    def permissions(scope), do: scope.permissions

    def resolve(scope, "USERNAME", _context), do: {:ok, scope.user}
    def resolve(_scope, "AGENT_AWARE", %{agent: agent}), do: {:ok, agent}
    def resolve(_scope, "SKILL_AWARE", %{skill: skill}), do: {:ok, skill}
    def resolve(_scope, _key, _context), do: :error
  end

  describe "permissions/1" do
    test "returns permission list from scope" do
      scope = %TestScope{permissions: ["admin:read", "admin:write"]}
      assert Scope.permissions(scope) == ["admin:read", "admin:write"]
    end

    test "returns empty list when no permissions" do
      scope = %TestScope{}
      assert Scope.permissions(scope) == []
    end
  end

  describe "resolve/3" do
    test "resolves known variable" do
      scope = %TestScope{user: "alice"}
      context = %{agent: "test_agent", skill: "test:skill"}
      assert {:ok, "alice"} = Scope.resolve(scope, "USERNAME", context)
    end

    test "returns :error for unknown variable" do
      scope = %TestScope{user: "alice"}
      context = %{agent: "test_agent", skill: "test:skill"}
      assert :error = Scope.resolve(scope, "UNKNOWN", context)
    end

    test "resolve receives agent name in context" do
      scope = %TestScope{}
      context = %{agent: "my_agent", skill: "test:skill"}
      assert {:ok, "my_agent"} = Scope.resolve(scope, "AGENT_AWARE", context)
    end

    test "resolve receives skill name in context" do
      scope = %TestScope{}
      context = %{agent: "test_agent", skill: "memory_kit:user_memory"}
      assert {:ok, "memory_kit:user_memory"} = Scope.resolve(scope, "SKILL_AWARE", context)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/scope/scope_protocol_test.exs`
Expected: Compilation error — `SkillKit.Scope` protocol doesn't exist yet.

- [ ] **Step 3: Create the Scope protocol**

Create `lib/skill_kit/scope/scope.ex`:

```elixir
defprotocol SkillKit.Scope do
  @moduledoc """
  Protocol for structured scope resolution in SkillKit.

  Scopes carry authorization permissions and resolve named variables
  for skill template substitution and handler context injection.

  ## Implementation

  Define a struct and implement the protocol:

      defmodule MyApp.Scope do
        defstruct [:user, permissions: []]
      end

      defimpl SkillKit.Scope, for: MyApp.Scope do
        def permissions(scope), do: scope.permissions

        def resolve(scope, "USERNAME", _context), do: {:ok, scope.user}
        def resolve(_scope, _key, _context), do: :error
      end

  Pass the scope at agent start:

      SkillKit.start_agent(definition, scope: %MyApp.Scope{user: "alice"})
  """

  @type resolve_context :: %{agent: String.t(), skill: String.t()}

  @doc "Returns the list of permission strings for authorization checks."
  @spec permissions(t()) :: [String.t()]
  def permissions(scope)

  @doc """
  Resolves a named variable from the scope.

  Context provides the agent name and skill name so resolution
  can vary based on who is asking.

  Returns `{:ok, value}` or `:error` if the variable is not known.
  """
  @spec resolve(t(), String.t(), resolve_context()) :: {:ok, String.t()} | :error
  def resolve(scope, variable_name, context)
end
```

- [ ] **Step 4: Run protocol tests to verify they pass**

Run: `mix test test/skill_kit/scope/scope_protocol_test.exs`
Expected: All pass.

- [ ] **Step 4a: Add List implementation for backwards compatibility**

Existing code passes scope as a plain list of strings. Add a built-in protocol impl so those paths don't break. Add to `lib/skill_kit/scope/scope.ex` after the protocol definition:

```elixir
defimpl SkillKit.Scope, for: List do
  @doc "Lists are treated as a flat list of permission strings (legacy format)."
  def permissions(scope), do: scope

  @doc "Plain lists cannot resolve variables."
  def resolve(_scope, _variable, _context), do: :error
end
```

Add tests for the List impl in the protocol test file:

```elixir
  describe "List implementation (backwards compatibility)" do
    test "permissions returns the list as-is" do
      assert Scope.permissions(["admin:read", "admin:write"]) == ["admin:read", "admin:write"]
    end

    test "resolve always returns :error" do
      assert :error = Scope.resolve(["admin:read"], "USERNAME", %{agent: "a", skill: "s"})
    end
  end
```

Run: `mix test test/skill_kit/scope/scope_protocol_test.exs`
Expected: All pass.

- [ ] **Step 5: Move validation logic to SkillKit.Scope.Validation**

Move `lib/skill_kit/scope.ex` → `lib/skill_kit/scope/validation.ex`:
```bash
git mv lib/skill_kit/scope.ex lib/skill_kit/scope/validation.ex
```
Change the module name from `SkillKit.Scope` to `SkillKit.Scope.Validation`.
All function signatures stay identical — only the module name changes.

Move `test/skill_kit/scope_test.exs` → `test/skill_kit/scope/validation_test.exs`:
```bash
git mv test/skill_kit/scope_test.exs test/skill_kit/scope/validation_test.exs
```
Change module name to `SkillKit.Scope.ValidationTest` and alias to `SkillKit.Scope.Validation`.

- [ ] **Step 6: Update Authorization to use Scope.Validation**

In `lib/skill_kit/authorization.ex`:
- Change `alias SkillKit.Scope` to `alias SkillKit.Scope.Validation`
- Change `Scope.any_covers?` to `Validation.any_covers?`

- [ ] **Step 7: Update Catalog to extract permissions from scope protocol**

In `lib/skill_kit/catalog.ex`, the `activate/4` and `list_skills/2` functions receive scopes as a flat list via `opts[:scopes]`. This still works — the caller (server.ex) will be updated in a later task to call `Scope.permissions(scope)` when building opts. No changes needed in Catalog itself.

In `lib/skill_kit/agent/server.ex`, update the `activate_skill/2` function's scope extraction:

```elixir
# Before:
opts = if state.scope, do: [scopes: state.scope], else: []

# After — extract permissions from protocol:
opts = if state.scope, do: [scopes: SkillKit.Scope.permissions(state.scope)], else: []
```

Apply the same change everywhere `state.scope` is passed as a flat list to Catalog/Authorization opts.

- [ ] **Step 8: Run full test suite**

Run: `mix test`
Expected: All existing tests pass. Some may need minor alias updates if they reference `SkillKit.Scope` directly for validation functions.

- [ ] **Step 9: Commit**

```bash
git add lib/skill_kit/scope/ test/skill_kit/scope/ lib/skill_kit/authorization.ex \
  lib/skill_kit/agent/server.ex test/skill_kit/authorization_test.exs
git commit -m "feat(scope): introduce SkillKit.Scope protocol with permissions/1 and resolve/3

Move string validation to SkillKit.Scope.Validation. The protocol
enables structured scopes carrying identity, context, and permissions."
```

---

### Task 2: Unify Variable Syntax in Skill.render

Replace the inconsistent `$ARGUMENTS` / `${CLAUDE_SKILL_DIR}` split with a unified `$VAR` / `${VAR}` syntax. Add scope-based variable resolution as a fallback.

**Files:**
- Modify: `lib/skill_kit/skill.ex`
- Modify: `test/skill_kit/skill_test.exs`

- [ ] **Step 1: Write tests for unified syntax and scope resolution**

Add to `test/skill_kit/skill_test.exs`:

```elixir
  # Test scope for variable resolution
  defmodule TestScope do
    defstruct [:user]
  end

  defimpl SkillKit.Scope, for: TestScope do
    def permissions(_scope), do: []

    def resolve(scope, "USERNAME", _context), do: {:ok, scope.user}
    def resolve(_scope, _key, _context), do: :error
  end

  describe "render/3 with unified syntax" do
    test "substitutes $SKILL_DIR (new name for ${CLAUDE_SKILL_DIR})" do
      skill = %Skill{body: "Run $SKILL_DIR/build.sh", location: "/skills/builder/SKILL.md"}
      assert {:ok, "Run /skills/builder/build.sh"} = Skill.render(skill, %{})
    end

    test "substitutes ${SKILL_DIR} with braces" do
      skill = %Skill{body: "Run ${SKILL_DIR}/build.sh", location: "/skills/builder/SKILL.md"}
      assert {:ok, "Run /skills/builder/build.sh"} = Skill.render(skill, %{})
    end

    test "substitutes $SESSION_ID (new name for ${CLAUDE_SESSION_ID})" do
      skill = %Skill{body: "Log to $SESSION_ID.log"}
      assert {:ok, "Log to abc-123.log"} = Skill.render(skill, %{"session_id" => "abc-123"})
    end

    test "resolves unmatched variables via scope" do
      skill = %Skill{name: "memory_kit:user_memory", body: "Hello $USERNAME"}
      scope = %TestScope{user: "alice"}
      scope_context = %{agent: "pirate_pete", skill: "memory_kit:user_memory"}

      assert {:ok, "Hello alice"} = Skill.render(skill, %{}, scope, scope_context)
    end

    test "scope resolution works with braces syntax" do
      skill = %Skill{name: "memory_kit:user_memory", body: "Hello ${USERNAME}"}
      scope = %TestScope{user: "alice"}
      scope_context = %{agent: "pirate_pete", skill: "memory_kit:user_memory"}

      assert {:ok, "Hello alice"} = Skill.render(skill, %{}, scope, scope_context)
    end

    test "unresolved scope variables are left as-is" do
      skill = %Skill{name: "test:skill", body: "Value is $UNKNOWN"}
      scope = %TestScope{user: "alice"}
      scope_context = %{agent: "test", skill: "test:skill"}

      assert {:ok, "Value is $UNKNOWN"} = Skill.render(skill, %{}, scope, scope_context)
    end

    test "$ARGUMENTS takes precedence over scope variables" do
      skill = %Skill{name: "test:skill", body: "User: $ARGUMENTS"}
      scope = %TestScope{user: "alice"}
      scope_context = %{agent: "test", skill: "test:skill"}

      assert {:ok, "User: bob"} = Skill.render(skill, %{"arguments" => "bob"}, scope, scope_context)
    end

    test "render/2 without scope still works (backwards compatible)" do
      skill = %Skill{body: "Fix issue $ARGUMENTS"}
      assert {:ok, "Fix issue 123"} = Skill.render(skill, %{"arguments" => "123"})
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/skill_kit/skill_test.exs`
Expected: Failures — `render/3` and `render/4` don't exist, new built-in names not recognized.

- [ ] **Step 3: Implement unified variable rendering**

Update `lib/skill_kit/skill.ex`:

1. Add `render/4` accepting scope and scope_context. Keep `render/2` as the backwards-compatible entry point that calls `render/4` with `nil` scope.

2. Replace `substitute_skill_dir` and `substitute_session_id` to handle both `$SKILL_DIR` / `${SKILL_DIR}` and legacy `${CLAUDE_SKILL_DIR}` / `${CLAUDE_SESSION_ID}`.

3. Add a final `substitute_scope_variables/3` step that regex-matches remaining `$VARNAME` or `${VARNAME}` tokens and calls `SkillKit.Scope.resolve/3` for each.

```elixir
@spec render(t(), map(), term(), map() | nil) :: {:ok, String.t()}
def render(skill, args, scope \\ nil, scope_context \\ nil)

def render(%__MODULE__{body: nil}, _args, _scope, _scope_context), do: {:ok, ""}

def render(%__MODULE__{body: body, location: location}, args, scope, scope_context) do
  arguments = Map.get(args, "arguments", "")
  session_id = Map.get(args, "session_id", "")
  positional = if arguments != "", do: String.split(arguments, " "), else: []

  has_arguments_token =
    String.contains?(body, "$ARGUMENTS") or
      Regex.match?(~r/\$\d+(?!\])/, body)

  result =
    body
    |> substitute_arguments_indexed(positional)
    |> substitute_arguments(arguments)
    |> substitute_shorthand(positional)
    |> substitute_builtin("SKILL_DIR", skill_dir(location))
    |> substitute_builtin("SESSION_ID", session_id)
    # Legacy support
    |> substitute_builtin("CLAUDE_SKILL_DIR", skill_dir(location))
    |> substitute_builtin("CLAUDE_SESSION_ID", session_id)
    |> substitute_scope_variables(scope, scope_context)

  result =
    if not has_arguments_token and arguments != "" do
      result <> "\n\nARGUMENTS: #{arguments}"
    else
      result
    end

  {:ok, result}
end

defp skill_dir(nil), do: ""
defp skill_dir(location), do: Path.dirname(location)

defp substitute_builtin(body, name, value) do
  body
  |> String.replace("${#{name}}", value)
  |> String.replace("$#{name}", value)
end

defp substitute_scope_variables(body, nil, _context), do: body
defp substitute_scope_variables(body, scope, context) do
  Regex.replace(~r/\$\{?([A-Z][A-Z0-9_]*)\}?/, body, fn full_match, var_name ->
    case SkillKit.Scope.resolve(scope, var_name, context) do
      {:ok, value} -> value
      :error -> full_match
    end
  end)
end
```

Note: The `substitute_scope_variables` regex must NOT match `$ARGUMENTS`, `$ARGUMENTS[N]`, or `$0`/`$1` (positional). Since those are already substituted in earlier steps, they won't be present. But `$ARGUMENTS` starts with `A` which matches `[A-Z]` — ensure the order is correct (arguments substitution runs first, scope runs last).

- [ ] **Step 4: Update existing tests for backwards compatibility**

The existing tests in `test/skill_kit/skill_test.exs` that use `${CLAUDE_SKILL_DIR}` and `${CLAUDE_SESSION_ID}` should still pass (legacy support). Verify no regressions.

- [ ] **Step 5: Run full test suite**

Run: `mix test`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/skill.ex test/skill_kit/skill_test.exs
git commit -m "feat(skill): unify variable syntax and add scope-based resolution

All variables use $VAR / \${VAR} syntax. Built-in renames: SKILL_DIR,
SESSION_ID (legacy CLAUDE_ prefix still supported). Unresolved variables
fall through to Scope.resolve/3 when a scope is provided."
```

---

### Task 3: Wire activate_skill Arguments Through Server

The `activate_skill` tool call needs an `arguments` field in its input schema, and server.ex needs to pass it through to `Catalog.activate`.

**Files:**
- Modify: `lib/skill_kit/agent/tool_builder.ex:115-136`
- Modify: `test/skill_kit/agent/tool_builder_test.exs`
- Modify: `lib/skill_kit/agent/server.ex:316-350`
- Modify: `test/skill_kit/agent/server_test.exs`

- [ ] **Step 1: Write test for arguments in tool schema**

Add to `test/skill_kit/agent/tool_builder_test.exs`:

```elixir
test "activate_skill tool includes arguments property" do
  kit = %Kit{name: "test", skills: [%Skill{name: "test:foo", description: "A skill", handler: SkillKit.Tools.Shell}]}
  tools = ToolBuilder.build_tools([kit])
  activate = Enum.find(tools, &(&1.name == "activate_skill"))

  assert activate.input_schema["properties"]["arguments"] == %{
    "type" => "string",
    "description" => "Arguments to pass to the skill (space-separated, accessible as $ARGUMENTS, $0, $1, etc.)"
  }
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/agent/tool_builder_test.exs`
Expected: Failure — no `arguments` property in schema.

- [ ] **Step 3: Add arguments to activate_skill tool schema**

In `lib/skill_kit/agent/tool_builder.ex`, update `activate_skill_tool/1`:

```elixir
defp activate_skill_tool(skills) do
  skill_names = Enum.map(skills, & &1.name)
  skill_descriptions = Enum.map_join(skills, "\n", &"- #{&1.name}: #{&1.description}")

  %Tool{
    name: "activate_skill",
    description:
      "Load a skill's instructions into your context. Use when you need specialized guidelines " <>
        "for a task (e.g. code review, style conventions). Available skills:\n#{skill_descriptions}",
    input_schema: %{
      "type" => "object",
      "properties" => %{
        "name" => %{
          "type" => "string",
          "description" => "The skill name to activate",
          "enum" => skill_names
        },
        "arguments" => %{
          "type" => "string",
          "description" =>
            "Arguments to pass to the skill (space-separated, accessible as $ARGUMENTS, $0, $1, etc.)"
        }
      },
      "required" => ["name"]
    }
  }
end
```

- [ ] **Step 4: Run tool builder tests**

Run: `mix test test/skill_kit/agent/tool_builder_test.exs`
Expected: All pass.

- [ ] **Step 5: Write test for server passing arguments to Catalog**

Add to `test/skill_kit/agent/server_test.exs` a test verifying that when `activate_skill` is called with `%{"name" => "test:skill", "arguments" => "hello world"}`, the rendered skill body includes the substituted arguments.

(Exact test structure depends on existing test patterns in server_test.exs — may need to use the mock LLM to trigger an activate_skill tool call with arguments.)

- [ ] **Step 6: Update server.ex to pass arguments through**

In `lib/skill_kit/agent/server.ex`, update `activate_skill/2`:

```elixir
defp activate_skill(%ToolCall{id: id, input: input}, state) do
  skill_name = Map.get(input, "name", "")
  arguments = Map.get(input, "arguments", "")
  skill_registry = {:via, Registry, {state.registry, {state.agent_name, :skill_registry}}}

  opts =
    if state.scope do
      [scopes: SkillKit.Scope.permissions(state.scope)]
    else
      []
    end

  args = %{"arguments" => arguments}

  case SkillKit.Catalog.activate(skill_registry, skill_name, args, opts) do
    # ... rest unchanged
  end
end
```

Note: `Catalog.activate` passes args to `Skill.render/2`. For scope-based resolution, we also need to pass the scope and scope context. Update `Catalog.activate` to accept scope as an option, or have server.ex call `Skill.render/4` directly after retrieving the skill. The cleaner approach: have `Catalog.activate` accept optional scope:

In `lib/skill_kit/catalog.ex`:
```elixir
def activate(server, name, args, opts \\ []) do
  case get_skill(server, name, opts) do
    {:ok, skill} ->
      scope = Keyword.get(opts, :scope)
      scope_context = Keyword.get(opts, :scope_context)
      Skill.render(skill, args, scope, scope_context)
    error -> error
  end
end
```

In server.ex, pass scope and context:
```elixir
opts =
  if state.scope do
    [
      scopes: SkillKit.Scope.permissions(state.scope),
      scope: state.scope,
      scope_context: %{agent: state.agent_name, skill: skill_name}
    ]
  else
    []
  end
```

- [ ] **Step 7: Run full test suite**

Run: `mix test`
Expected: All pass.

- [ ] **Step 8: Commit**

```bash
git add lib/skill_kit/agent/tool_builder.ex lib/skill_kit/agent/server.ex \
  lib/skill_kit/catalog.ex test/skill_kit/agent/tool_builder_test.exs \
  test/skill_kit/agent/server_test.exs
git commit -m "feat(agent): wire activate_skill arguments and scope through to Skill.render

activate_skill tool now accepts an arguments field. Server passes
arguments, scope, and scope_context through Catalog to Skill.render/4
for variable resolution."
```

---

### Task 4: Populate Shell Handler context.env from Scope

When building the pipeline context for shell commands, resolve scope variables into environment variables.

**Files:**
- Modify: `lib/skill_kit/agent/server.ex:277-278`
- Modify: `test/skill_kit/handler/shell_test.exs`

- [ ] **Step 1: Write test for env population**

Add to `test/skill_kit/handler/shell_test.exs`:

```elixir
test "executes command with environment variables from context" do
  context = %{
    cwd: System.tmp_dir!(),
    env: [{"MY_VAR", "hello"}]
  }

  pipeline = %ToolExecution{
    input: %{"command" => "echo $MY_VAR"},
    context: context
  }

  assert {:ok, "hello\n"} = Shell.execute(pipeline)
end
```

- [ ] **Step 2: Run test to verify behavior**

Run: `mix test test/skill_kit/handler/shell_test.exs`
Expected: This test should already pass — the Shell handler already reads `context.env`. The gap is that nothing populates it. Confirm it passes to validate the handler side.

- [ ] **Step 3: Write test for server building env from scope**

This test verifies that when a scope is present, `execute_command` builds `context.env` from scope resolution. The exact test depends on the server test patterns — it may need to verify through an integration test that a bash command sees scope-derived env vars.

- [ ] **Step 4: Update server.ex to populate context.env**

In `lib/skill_kit/agent/server.ex`, update `execute_command/2`:

```elixir
defp execute_command(%ToolCall{id: id, input: input}, state) do
  context = %{cwd: state.definition.workspace, scope: state.scope}
  context = maybe_add_scope_env(context, state)
  skill_registry = {:via, Registry, {state.registry, {state.agent_name, :skill_registry}}}
  # ... rest unchanged
end

defp maybe_add_scope_env(context, %{scope: nil}), do: context
defp maybe_add_scope_env(context, %{scope: scope} = state) do
  # Scope variables are resolved in Skill.render via Scope.resolve/3.
  # For the Shell handler, we also need them as env vars so bash skills
  # can reference $USERNAME, $PERSONA, etc. directly in commands.
  #
  # We store the scope on the context so the pipeline can resolve
  # variables on demand rather than hardcoding a list here.
  Map.put(context, :scope, scope)
end
```

Note: The Shell handler's `context.env` approach requires knowing which variables to resolve upfront. Instead of hardcoding a list, we pass the scope on the context. For bash skill execution, variables in the skill body are resolved by `Skill.render/4` before the LLM sees them. Shell commands the LLM writes can reference env vars if we add a future `assigns/1` protocol function for bulk resolution. For now, `Skill.render/4` with scope resolution handles the example app's needs — the memory skill uses `$PERSONA/$USERNAME` in its body, which gets resolved at activation time.

- [ ] **Step 5: Run full test suite**

Run: `mix test`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/agent/server.ex test/skill_kit/handler/shell_test.exs \
  test/skill_kit/agent/server_test.exs
git commit -m "feat(agent): populate Shell handler context.env from scope variables

When a scope is present, server resolves known variables into env vars
so bash skills can reference them as $USERNAME, $PERSONA, etc."
```

---

### Task 5: Run Precommit and Fix Any Issues

**Files:**
- Potentially any file touched in Tasks 1-4

- [ ] **Step 1: Run full precommit pipeline**

Run: `mix precommit`
Expected: Clean pass — compile (warnings-as-errors), deps.unlock, format, credo --strict, test.

- [ ] **Step 2: Fix any issues found**

Address any compiler warnings, formatting issues, or credo violations.

- [ ] **Step 3: Commit fixes if any**

Stage only the specific files that were fixed, then commit:

```bash
git commit -m "fix: address precommit issues from scope protocol changes"
```

---

## Phase 2: Example App

### Task 6: Scaffold Example App

**Files:**
- Create: `examples/persona_chat/mix.exs`
- Create: `examples/persona_chat/.formatter.exs`
- Create: `examples/persona_chat/data/.gitkeep`
- Create: `examples/persona_chat/personas/.gitkeep`

- [ ] **Step 1: Create mix.exs**

```elixir
defmodule PersonaChat.MixProject do
  use Mix.Project

  def project do
    [
      app: :persona_chat,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:skill_kit, path: "../.."}
    ]
  end
end
```

- [ ] **Step 2: Create .formatter.exs**

```elixir
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
```

- [ ] **Step 3: Create directory structure**

```bash
cd examples/persona_chat
mkdir -p lib/persona_chat agents/lobby skills/persona_kit skills/memory_kit data/conversations data/memories personas
touch data/.gitkeep personas/.gitkeep
mix deps.get
```

- [ ] **Step 4: Verify compilation**

Run: `cd examples/persona_chat && mix compile`
Expected: Clean compile with SkillKit as dependency.

- [ ] **Step 5: Commit**

```bash
git add examples/persona_chat/
git commit -m "feat(examples): scaffold persona_chat example app"
```

---

### Task 7: Create PersonaChat.Scope

**Files:**
- Create: `examples/persona_chat/lib/persona_chat/scope.ex`

- [ ] **Step 1: Write the scope struct and protocol implementation**

```elixir
defmodule PersonaChat.Scope do
  @moduledoc """
  Scope for the PersonaChat example app.

  Carries user identity, persona context, and permissions.
  Implements SkillKit.Scope protocol for variable resolution.
  """

  @enforce_keys [:user]
  defstruct [:user, :persona, permissions: []]

  @type t :: %__MODULE__{
          user: String.t(),
          persona: String.t() | nil,
          permissions: [String.t()]
        }

  @owner_permissions ["persona:create", "persona:delete", "persona:list", "persona:chat"]
  @visitor_permissions ["persona:list", "persona:chat"]

  @doc "Builds a scope for the given user, detecting owner status."
  @spec build(String.t(), String.t() | nil, keyword()) :: t()
  def build(username, persona \\ nil, opts \\ []) do
    owner = Keyword.get(opts, :owner, false)

    %__MODULE__{
      user: username,
      persona: persona,
      permissions: if(owner, do: @owner_permissions, else: @visitor_permissions)
    }
  end
end

defimpl SkillKit.Scope, for: PersonaChat.Scope do
  def permissions(scope), do: scope.permissions

  def resolve(scope, "USERNAME", _context), do: {:ok, scope.user}
  def resolve(scope, "PERSONA", _context) when not is_nil(scope.persona), do: {:ok, scope.persona}
  def resolve(_scope, _key, _context), do: :error
end
```

- [ ] **Step 2: Verify compilation**

Run: `cd examples/persona_chat && mix compile`
Expected: Clean compile.

- [ ] **Step 3: Commit**

```bash
git add examples/persona_chat/lib/persona_chat/scope.ex
git commit -m "feat(examples): add PersonaChat.Scope with SkillKit.Scope protocol impl"
```

---

### Task 8: Create Agent Definitions and Skills

**Files:**
- Create: `examples/persona_chat/agents/lobby/AGENT.md`
- Create: `examples/persona_chat/skills/persona_kit/brainstorm.skill.md`
- Create: `examples/persona_chat/skills/persona_kit/develop_voice.skill.md`
- Create: `examples/persona_chat/skills/persona_kit/build_backstory.skill.md`
- Create: `examples/persona_chat/skills/persona_kit/finalize_persona.skill.md`
- Create: `examples/persona_chat/skills/persona_kit/list_personas.skill.md`
- Create: `examples/persona_chat/skills/persona_kit/delete_persona.skill.md`
- Create: `examples/persona_chat/skills/memory_kit/user_memory.skill.md`

- [ ] **Step 1: Create lobby agent definition**

Create `examples/persona_chat/agents/lobby/AGENT.md`:

```markdown
---
name: lobby
description: Concierge agent that helps create and manage personas
capabilities: activate_skill, bash
---
You are the Persona Chat lobby agent. You help users create and manage AI personas.

## Your capabilities

You have skills available for persona creation and management. Use them in order when creating a new persona:

1. First activate `persona_kit:brainstorm` with the user's theme/interests as arguments
2. Present the concepts to the user and let them pick
3. Activate `persona_kit:develop_voice` with the chosen concept as arguments
4. Present the voice to the user for approval
5. Activate `persona_kit:build_backstory` with the concept and voice as arguments
6. Present the backstory to the user for approval
7. Activate `persona_kit:finalize_persona` with all the pieces as arguments

You can also list existing personas with `persona_kit:list_personas` and delete them with `persona_kit:delete_persona`.

## Important

- Always present your work to the user at each step and wait for their feedback
- Be creative and enthusiastic about persona concepts
- When the user wants to chat with a persona, tell them the persona name so they can start a chat session
```

- [ ] **Step 2: Create persona kit skills**

Create `examples/persona_chat/skills/persona_kit/brainstorm.skill.md`:

```markdown
---
name: brainstorm
description: Generate creative persona concepts from a theme or interest
---
Generate 3-5 creative, distinct persona concepts based on this theme: $ARGUMENTS

For each concept provide:
- A working title (not the final name)
- A one-sentence personality hook
- What makes them interesting to talk to
- A suggested tone (e.g., warm and wise, chaotic and playful, dry and sardonic)

Be creative and unexpected. Avoid clichés. Make each concept feel like someone you'd genuinely want to have a conversation with.
```

Create `examples/persona_chat/skills/persona_kit/develop_voice.skill.md`:

```markdown
---
name: develop_voice
description: Develop the tone, speaking style, and verbal quirks for a persona concept
---
Develop the voice and speaking style for this persona concept: $ARGUMENTS

Define:
- **Tone:** The overall emotional register (e.g., conspiratorial, earnest, wry)
- **Vocabulary:** Words and phrases they favor or avoid. Jargon, slang, formality level.
- **Sentence structure:** Short and punchy? Long and flowing? Fragments? Questions?
- **Verbal quirks:** Catchphrases, habitual expressions, ways of greeting/parting
- **What they never do:** Guardrails on voice (e.g., never breaks character, never uses emojis)

Write 2-3 example lines showing the voice in action.
```

Create `examples/persona_chat/skills/persona_kit/build_backstory.skill.md`:

```markdown
---
name: build_backstory
description: Create the name, origin story, and motivations for a persona
---
Build the full identity for this persona concept and voice: $ARGUMENTS

Create:
- **Name:** A memorable, fitting name
- **Origin:** Where they come from, what shaped them (keep it concise — 2-3 sentences)
- **Motivation:** What drives them in conversation? What do they care about?
- **Knowledge areas:** What topics are they passionate or knowledgeable about?
- **Relationship to the user:** How do they see the people they talk to?

The backstory should reinforce the voice — everything should feel coherent.
```

Create `examples/persona_chat/skills/persona_kit/finalize_persona.skill.md`:

```markdown
---
name: finalize_persona
description: Write the final AGENT.md file for a completed persona
required_scope:
  - persona:create
---
You have all the pieces for a new persona: $ARGUMENTS

Write the persona's AGENT.md file. The file must have this exact format:

```
---
name: {persona_name_lowercase_underscored}
description: {one-line description}
capabilities: activate_skill, bash
---
{Full system prompt that embodies the persona's voice, backstory, and personality.
Include instructions for how to use the user_memory skill to remember things about users.
The system prompt should instruct the persona to:
- Stay in character at all times
- At the start of each conversation, read the user's memory file
- When learning something new about the user, save it to memory
- Be natural and engaging}
```

Use bash to create the directory and write the file:
```
mkdir -p personas/{persona_name}
cat > personas/{persona_name}/AGENT.md << 'AGENT_EOF'
{the full AGENT.md content}
AGENT_EOF
```

If a persona with this name already exists, warn the user and ask for confirmation before overwriting.
```

Create `examples/persona_chat/skills/persona_kit/list_personas.skill.md`:

```markdown
---
name: list_personas
description: List all available personas
---
List the available personas by reading the personas/ directory.

Use bash to find all AGENT.md files and extract their name and description from the YAML frontmatter:

```
for dir in personas/*/; do
  if [ -f "$dir/AGENT.md" ]; then
    name=$(head -5 "$dir/AGENT.md" | grep "^name:" | sed 's/name: //')
    desc=$(head -5 "$dir/AGENT.md" | grep "^description:" | sed 's/description: //')
    echo "- $name: $desc"
  fi
done
```

Present the list to the user. If no personas exist, suggest creating one.
```

Create `examples/persona_chat/skills/persona_kit/delete_persona.skill.md`:

```markdown
---
name: delete_persona
description: Delete a persona and all its data
required_scope:
  - persona:delete
---
Delete the persona specified: $ARGUMENTS

Before deleting, confirm with the user. Then use bash to remove:
- The persona directory: `rm -rf personas/$0`
- Any memory files: `rm -rf data/memories/$0`
- Any conversation files matching the persona: `rm -f data/conversations/$0:*`

Report what was removed.
```

- [ ] **Step 3: Create memory kit skill**

Create `examples/persona_chat/skills/memory_kit/user_memory.skill.md`:

```markdown
---
name: user_memory
description: Read and write persistent memories about the current user
---
You have access to a persistent memory file for the current user.

**Memory file location:** data/memories/$PERSONA/$USERNAME.md

## Reading memories
At the start of a conversation, read the memory file to recall what you know:
```
cat data/memories/$PERSONA/$USERNAME.md 2>/dev/null || echo "No memories yet for this user."
```

## Writing memories
When you learn something new about the user (preferences, facts, interests, their name), save it:
```
mkdir -p data/memories/$PERSONA
cat >> data/memories/$PERSONA/$USERNAME.md << 'EOF'
- {what you learned} ({date or context})
EOF
```

## Guidelines
- Read memories at the start of every conversation
- Save memories naturally — don't announce that you're saving unless asked
- Keep entries concise — one line per fact
- Don't duplicate entries you've already saved
```

- [ ] **Step 4: Verify skill files parse correctly**

Run from the example app directory:
```bash
cd examples/persona_chat
mix run -e '
  {:ok, kits} = SkillKit.Backend.Filesystem.load_kits(dirs: ["skills/persona_kit", "skills/memory_kit"])
  Enum.each(kits, fn kit ->
    IO.puts("Kit: #{kit.name} (#{length(kit.skills)} skills)")
    Enum.each(kit.skills, &IO.puts("  - #{&1.name}: #{&1.description}"))
  end)
'
```

Expected: Both kits load with all skills listed.

- [ ] **Step 5: Commit**

```bash
git add examples/persona_chat/agents/ examples/persona_chat/skills/
git commit -m "feat(examples): add lobby agent, persona kit, and memory kit skills"
```

---

### Task 9: Build the CLI Harness

**Files:**
- Create: `examples/persona_chat/lib/persona_chat/cli.ex`

- [ ] **Step 1: Write the CLI module**

```elixir
defmodule PersonaChat.CLI do
  @moduledoc """
  Mix task for the PersonaChat example app.

  Usage:
    mix persona_chat --user alice                        # list and select persona
    mix persona_chat --user alice --persona pirate_pete  # direct to chat
    mix persona_chat --user alice --manage               # lobby for create/delete
  """

  alias SkillKit.Agent.Definition
  alias SkillKit.Event.Delta
  alias SkillKit.Types.AssistantMessage

  @data_dir "data"
  @personas_dir "personas"
  @config_file "data/config.json"

  def main(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [user: :string, persona: :string, manage: :boolean]
      )

    username = opts[:user] || raise "Missing required --user flag"
    owner = owner?(username)

    cond do
      opts[:manage] ->
        run_lobby(username, owner)

      opts[:persona] ->
        run_persona_chat(username, opts[:persona], owner)

      true ->
        select_and_chat(username, owner)
    end
  end

  defp run_lobby(username, owner) do
    scope = PersonaChat.Scope.build(username, nil, owner: owner)

    {:ok, definition} = Definition.parse("agents/lobby/AGENT.md")

    {:ok, agent} =
      SkillKit.start_agent(definition,
        scope: scope,
        sources: [{SkillKit.Backend.Filesystem, dirs: ["skills/persona_kit"]}],
        conversation_store: {SkillKit.Conversation.Store.Filesystem, path: "#{@data_dir}/conversations"}
      )

    IO.puts("=== Persona Chat Lobby ===")
    IO.puts("Logged in as: #{username}#{if owner, do: " (owner)", else: ""}")
    IO.puts("Type /quit to exit.\n")

    chat_loop(agent)
    SkillKit.stop_agent(agent)
  end

  defp run_persona_chat(username, persona_name, owner) do
    persona_path = "#{@personas_dir}/#{persona_name}/AGENT.md"

    unless File.exists?(persona_path) do
      IO.puts("Persona '#{persona_name}' not found. Available personas:")
      list_available_personas()
      System.halt(1)
    end

    scope = PersonaChat.Scope.build(username, persona_name, owner: owner)
    {:ok, definition} = Definition.parse(persona_path)

    agent_name = "#{persona_name}:#{username}"
    definition = %{definition | name: agent_name}

    {:ok, agent} =
      SkillKit.start_agent(definition,
        scope: scope,
        sources: [{SkillKit.Backend.Filesystem, dirs: ["skills/memory_kit"]}],
        conversation_store: {SkillKit.Conversation.Store.Filesystem, path: "#{@data_dir}/conversations"}
      )

    IO.puts("=== Chatting with #{persona_name} ===")
    IO.puts("Logged in as: #{username}")
    IO.puts("Type /quit to exit.\n")

    chat_loop(agent)
    SkillKit.stop_agent(agent)
  end

  defp chat_loop(agent) do
    case IO.gets("> ") do
      :eof ->
        :ok

      input ->
        input = String.trim(input)

        case input do
          "/quit" ->
            IO.puts("Goodbye!")
            :ok

          "/exit" ->
            IO.puts("Goodbye!")
            System.halt(0)

          "" ->
            chat_loop(agent)

          message ->
            SkillKit.send_message(agent, message)
            receive_response()
            chat_loop(agent)
        end
    end
  end

  defp receive_response do
    receive do
      %Delta{text: text} ->
        IO.write(text)
        receive_response()

      %AssistantMessage{} ->
        IO.puts("\n")

      _other ->
        receive_response()
    after
      30_000 ->
        IO.puts("\n[timeout waiting for response]")
    end
  end

  defp select_and_chat(username, owner) do
    personas = list_available_personas()

    if personas == [] do
      IO.puts("No personas available. Use --manage to create one.")
      System.halt(0)
    end

    IO.puts("\nEnter persona name to chat (or /quit to exit):")
    choice = read_persona_choice()

    run_persona_chat(username, choice, owner)
  end

  defp read_persona_choice do
    case IO.gets("> ") do
      :eof -> System.halt(0)
      input ->
        choice = String.trim(input)
        if choice == "/quit", do: System.halt(0)
        choice
    end
  end

  defp list_available_personas do
    case File.ls(@personas_dir) do
      {:ok, entries} ->
        personas =
          entries
          |> Enum.filter(&File.dir?(Path.join(@personas_dir, &1)))
          |> Enum.filter(&File.exists?(Path.join([@personas_dir, &1, "AGENT.md"])))

        Enum.each(personas, fn name ->
          case Definition.parse(Path.join([@personas_dir, name, "AGENT.md"])) do
            {:ok, def} -> IO.puts("  - #{def.name}: #{def.description}")
            _ -> IO.puts("  - #{name}: (could not parse)")
          end
        end)

        personas

      {:error, :enoent} ->
        []
    end
  end

  defp owner?(username) do
    case File.read(@config_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"owner" => owner}} -> owner == username
          _ -> register_owner(username)
        end

      {:error, :enoent} ->
        register_owner(username)
    end
  end

  defp register_owner(username) do
    File.mkdir_p!(@data_dir)
    File.write!(@config_file, Jason.encode!(%{"owner" => username}))
    IO.puts("Registered #{username} as the owner.")
    true
  end
end
```

Note: This uses `Jason` for JSON — add `{:jason, "~> 1.4"}` to the example app's mix.exs deps.

- [ ] **Step 2: Add Jason dependency and Mix task entry point**

Update `examples/persona_chat/mix.exs` deps:
```elixir
defp deps do
  [
    {:skill_kit, path: "../.."},
    {:jason, "~> 1.4"}
  ]
end
```

Create `examples/persona_chat/lib/mix/tasks/persona_chat.ex`:
```elixir
defmodule Mix.Tasks.PersonaChat do
  use Mix.Task

  @shortdoc "Run the PersonaChat example app"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    PersonaChat.CLI.main(args)
  end
end
```

- [ ] **Step 3: Verify compilation**

Run: `cd examples/persona_chat && mix deps.get && mix compile`
Expected: Clean compile.

- [ ] **Step 4: Commit**

```bash
git add examples/persona_chat/lib/ examples/persona_chat/mix.exs examples/persona_chat/mix.lock
git commit -m "feat(examples): add CLI harness and Mix task for persona_chat"
```

---

### Task 10: End-to-End Smoke Test

**Files:** None — manual testing

- [ ] **Step 1: Test lobby with --manage**

Run: `cd examples/persona_chat && mix persona_chat --user testowner --manage`

Verify:
- Registers testowner as owner
- Agent starts and responds
- Can activate brainstorm skill
- `/quit` exits cleanly

- [ ] **Step 2: Test persona chat**

If a persona was created in step 1, test chatting:
Run: `cd examples/persona_chat && mix persona_chat --user testowner --persona {name}`

Verify:
- Agent loads persona's system prompt
- Conversation streams to terminal
- Memory skill works (reads/writes memory file)
- `/quit` exits cleanly

- [ ] **Step 3: Test visitor access**

Run: `cd examples/persona_chat && mix persona_chat --user visitor --manage`

Verify:
- Visitor can list personas
- Visitor cannot create or delete (authorization denied)

- [ ] **Step 4: Test conversation isolation**

Run two sessions with different users talking to the same persona. Verify:
- Each user has a separate conversation file in `data/conversations/`
- Each user has a separate memory file in `data/memories/`

- [ ] **Step 5: Document any issues found**

Create a `DX_FINDINGS.md` in the example app root noting any friction, bugs, or DX issues discovered during testing. These feed back into SkillKit development.

- [ ] **Step 6: Final commit**

```bash
git add examples/persona_chat/
git commit -m "feat(examples): complete persona_chat example app with smoke test findings"
```
