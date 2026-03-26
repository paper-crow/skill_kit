# Rename Shell, Sources→Skills, Remove Workspace — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename `SkillKit.Tools.Shell` → `SkillKit.Tools.Shell`, rename `:sources` → `:skills` throughout, and remove `:workspace` from Definition.

**Architecture:** Mechanical rename across the codebase. Shell handler moves from `lib/skill_kit/handler/shell.ex` to `lib/skill_kit/shell.ex`. All `:sources` references become `:skills`. Definition loses `:workspace` — the Shell handler defaults to `File.cwd!()` when no cwd is in context.

**Tech Stack:** Elixir, SkillKit

---

## File Structure

| Action | File | Change |
|--------|------|--------|
| Move | `lib/skill_kit/handler/shell.ex` → `lib/skill_kit/shell.ex` | Rename module to `SkillKit.Tools.Shell` |
| Move | `test/skill_kit/handler/shell_test.exs` → `test/skill_kit/shell_test.exs` | Rename module |
| Modify | `lib/skill_kit/handler/handler.ex` | Default handler → `SkillKit.Tools.Shell` |
| Modify | `lib/skill_kit/handler/behaviour.ex` | Doc reference |
| Modify | `lib/skill_kit/skill.ex` | Default handler → `SkillKit.Tools.Shell` |
| Modify | `lib/skill_kit/agent/tool_builder.ex` | All `Tools.Shell` refs → `SkillKit.Tools.Shell` |
| Modify | `lib/skill_kit/agent/server.ex` | `Tools.Shell` ref → `SkillKit.Tools.Shell`, remove `cwd` from context |
| Modify | `lib/skill_kit.ex` | `:sources` → `:skills`, docs, moduledoc |
| Modify | `lib/skill_kit/agent/agent.ex` | `:sources` → `:skills` |
| Modify | `lib/skill_kit/agent/infrastructure.ex` | `:sources` → `:skills` |
| Modify | `lib/skill_kit/supervisor.ex` | `:sources` → `:skills` |
| Modify | `lib/skill_kit/registry.ex` | `:sources` → `:skills` |
| Modify | `lib/skill_kit/agent/definition.ex` | Remove `:workspace` field |
| Modify | `lib/skill_kit/test.ex` | Remove workspace from test helper |
| Modify | `lib/mix/tasks/skill_kit.chat.ex` | `:sources` → `:skills`, remove workspace patch |
| Modify | `lib/mix/tasks/skill_kit.demo.ex` | `:sources` → `:skills`, remove workspace patch |
| Modify | `examples/persona_chat/lib/persona_chat/cli.ex` | `:sources` → `:skills` |
| Modify | Various test files | Update references |

---

### Task 1: Rename `SkillKit.Tools.Shell` → `SkillKit.Tools.Shell`

Move the file, rename the module, update all references across the codebase. This is a mechanical find-replace.

**Files to modify:**

Source files with `Tools.Shell` references (from grep):
- `lib/skill_kit/handler/shell.ex` → move to `lib/skill_kit/shell.ex`
- `lib/skill_kit.ex` (moduledoc)
- `lib/skill_kit/skill.ex` (default handler, docs)
- `lib/skill_kit/handler/handler.ex` (default handler, doc)
- `lib/skill_kit/handler/behaviour.ex` (doc)
- `lib/skill_kit/agent/tool_builder.ex` (default handlers, classifier)
- `lib/skill_kit/agent/server.ex` (activated skill check)
- `config/config.exs` (if present — not currently set)

Test files:
- `test/skill_kit/handler/shell_test.exs` → move to `test/skill_kit/shell_test.exs`
- `test/skill_kit/agent/tool_builder_test.exs`
- `test/skill_kit/skill_test.exs`
- `test/skill_kit/pipeline_test.exs`
- `test/skill_kit/backend/filesystem/parser_test.exs`
- `test/skill_kit/handler/tool_definition_test.exs`

- [ ] **Step 1: Move Shell handler file**

```bash
git mv lib/skill_kit/handler/shell.ex lib/skill_kit/shell.ex
git mv test/skill_kit/handler/shell_test.exs test/skill_kit/shell_test.exs
```

- [ ] **Step 2: Rename module in the moved files**

In `lib/skill_kit/shell.ex`: Change `defmodule SkillKit.Tools.Shell do` to `defmodule SkillKit.Tools.Shell do`

In `test/skill_kit/shell_test.exs`: Change module name and alias.

- [ ] **Step 3: Replace all `SkillKit.Tools.Shell` references in source files**

In each file listed above, replace `SkillKit.Tools.Shell` with `SkillKit.Tools.Shell`. Also replace `Tools.Shell` with `Shell` where it appears after an alias (check each file for its alias pattern).

Key changes:
- `lib/skill_kit/skill.ex` line 54: `handler: SkillKit.Tools.Shell` → `handler: SkillKit.Tools.Shell`
- `lib/skill_kit/handler/handler.ex` line 26: default → `SkillKit.Tools.Shell`
- `lib/skill_kit/agent/tool_builder.ex` line 30: default handlers → `[SkillKit.Tools.Shell]`
- `lib/skill_kit/agent/tool_builder.ex` line 46: `skill.handler == SkillKit.Tools.Shell` → `skill.handler == SkillKit.Tools.Shell`
- `lib/skill_kit/agent/server.ex` line 341: same pattern

- [ ] **Step 4: Replace all references in test files**

Same find-replace in all 6 test files listed above.

- [ ] **Step 5: Run tests**

Run: `mix test`
Expected: All 391 tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A  # safe here — only renames and content changes
git commit -m "refactor: rename SkillKit.Tools.Shell to SkillKit.Tools.Shell"
```

---

### Task 2: Rename `:sources` → `:skills` throughout

Rename the option key everywhere it appears in the public and internal API.

**Files with `:sources` references:**
- `lib/skill_kit.ex` — `start_agent`, `start_subagent`, `load_all_kits`, docs, moduledoc
- `lib/skill_kit/agent/agent.ex` — opts type, init, moduledoc
- `lib/skill_kit/agent/infrastructure.ex` — start_link, init
- `lib/skill_kit/supervisor.ex` — docs, init
- `lib/skill_kit/registry.ex` — handle_continue
- `lib/skill_kit/agent/server.ex` — state struct, init
- `lib/mix/tasks/skill_kit.chat.ex`
- `lib/mix/tasks/skill_kit.demo.ex`
- `examples/persona_chat/lib/persona_chat/cli.ex`
- Various test files

- [ ] **Step 1: Replace `:sources` with `:skills` in all source files**

This is a codebase-wide rename of the option key. Replace:
- `sources:` → `skills:` (in keyword lists)
- `:sources` → `:skills` (in Keyword.get/fetch calls)
- `sources =` → `skills =` (variable names in functions that extract the option)

IMPORTANT: Be careful not to replace unrelated uses of the word "sources" in comments or docs that describe the concept generically. Focus on the option key and variable name.

Also update `Backend` behaviour moduledoc if it references `:sources`.

- [ ] **Step 2: Replace in all test files**

Same rename in tests.

- [ ] **Step 3: Run tests**

Run: `mix test`
Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: rename :sources option to :skills throughout"
```

---

### Task 3: Remove `:workspace` from Definition

Remove the `:workspace` field from `Definition`, stop setting `cwd` in server context, and make the Shell handler default to `File.cwd!()`.

**Files:**
- `lib/skill_kit/agent/definition.ex` — remove `:workspace` from struct, type, enforce_keys, and parse logic
- `lib/skill_kit/agent/server.ex` — remove `cwd` from context maps
- `lib/skill_kit/shell.ex` — default to `File.cwd!()` when no cwd in context
- `lib/skill_kit/test.ex` — remove workspace from test helper
- `lib/skill_kit.ex` — remove `workspace: File.cwd!()` stopgap in start_agent/1
- `lib/mix/tasks/skill_kit.chat.ex` — remove workspace patching
- `lib/mix/tasks/skill_kit.demo.ex` — remove workspace patching
- `test/skill_kit/agent/definition_test.exs` — update tests
- Various other tests that construct Definitions with workspace

- [ ] **Step 1: Update Shell handler to default cwd**

In `lib/skill_kit/shell.ex`, update `maybe_add_cd`:

```elixir
defp maybe_add_cd(opts, %{cwd: cwd}) when is_binary(cwd), do: [{:cd, cwd} | opts]
defp maybe_add_cd(opts, _context), do: [{:cd, File.cwd!()} | opts]
```

This ensures bash always has an explicit working directory — defaulting to the process cwd when nothing is configured.

- [ ] **Step 2: Remove `cwd` from server.ex context**

In `lib/skill_kit/agent/server.ex`, two locations:

Line 279:
```elixir
# Before
context = %{cwd: state.definition.workspace, scope: state.scope}
# After
context = %{scope: state.scope}
```

Line 375:
```elixir
# Before
%{cwd: state.definition.workspace, scope: state.scope, agent_name: state.agent_name}
# After
%{scope: state.scope, agent_name: state.agent_name}
```

- [ ] **Step 3: Remove `:workspace` from Definition**

In `lib/skill_kit/agent/definition.ex`:
- Remove `:workspace` from `@type t`
- Remove `:workspace` from `@enforce_keys`
- Remove `:workspace` from `defstruct`
- Remove the workspace resolution logic in `build/3` (the `case Map.get(metadata, "workspace")` block)
- Remove `workspace: workspace` from the struct construction

- [ ] **Step 4: Remove workspace from start_agent/1 stopgap**

In `lib/skill_kit.ex`, the `start_agent/1` source-driven clause has:
```elixir
definition = %{definition | workspace: File.cwd!()}
```
Remove this line.

- [ ] **Step 5: Remove workspace patches from Mix tasks**

In `lib/mix/tasks/skill_kit.chat.ex`, remove the line:
```elixir
definition = %{definition | workspace: File.cwd!()}
```

In `lib/mix/tasks/skill_kit.demo.ex`, same removal.

- [ ] **Step 6: Update test helper**

In `lib/skill_kit/test.ex`, the test definition helper likely sets `workspace: "/tmp/test"`. Remove it.

- [ ] **Step 7: Update all tests that construct Definitions**

Any test that creates a `%Definition{...}` with a `workspace:` key needs updating. Search for `workspace:` in test files and remove the field. Some tests may also assert on workspace — remove those assertions.

- [ ] **Step 8: Run tests**

Run: `mix test`
Expected: All pass. Some shell tests that relied on `context.cwd` may need updating to pass cwd through context explicitly or verify the default behavior.

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "refactor: remove workspace from Definition, Shell handler defaults to cwd"
```

---

### Task 4: Run Precommit

- [ ] **Step 1: Run full precommit pipeline**

Run: `mix precommit`
Expected: Clean — compile, format, credo, test.

- [ ] **Step 2: Fix any issues**

- [ ] **Step 3: Commit fixes if any**
