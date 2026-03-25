# Source-Driven start_agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a keyword-list-only `start_agent/1` that discovers the top-level agent from backend sources, eliminating manual Definition parsing by callers.

**Architecture:** `Backend.Filesystem` gains root-agent detection (AGENT.md at source dir root). A new `start_agent/1` clause loads kits from sources, finds the single root agent, and delegates to the existing `start_agent/2`. The `Kit` struct gets a `:root_agent` field to carry the root agent separately from subagents.

**Tech Stack:** Elixir, SkillKit

**Spec:** `docs/superpowers/specs/2026-03-24-source-driven-start-agent-design.md`

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Modify | `lib/skill_kit/kit.ex` | Add `:root_agent` field to Kit struct |
| Modify | `lib/skill_kit/backend/filesystem/filesystem.ex` | `dirs:` → `dir:` (singular), detect root AGENT.md |
| Modify | `test/skill_kit/backend/filesystem_test.exs` | Update tests for `dir:` and root agent detection |
| Modify | `lib/skill_kit.ex` | Add `start_agent/1` clause |
| Create | `test/skill_kit/start_agent_test.exs` | Tests for source-driven start_agent |
| Modify | `lib/skill_kit/agent/agent.ex` | Update moduledoc example for `dir:` |
| Modify | `examples/persona_chat/lib/persona_chat/cli.ex` | Use new API |
| Modify | `examples/persona_chat/.skills/lobby/AGENT.md` | Move to `.skills/AGENT.md` |

---

### Task 1: Add `:root_agent` field to Kit struct

The Kit struct needs a way to carry the root agent separately from subagents. The `:agents` field continues to hold subagents. A new `:root_agent` field holds the single root agent (or nil).

**Files:**
- Modify: `lib/skill_kit/kit.ex`
- Modify: `test/skill_kit/kit_test.exs`

- [ ] **Step 1: Write test for new field**

Add to `test/skill_kit/kit_test.exs`:

```elixir
test "root_agent defaults to nil" do
  kit = %Kit{name: "test"}
  assert is_nil(kit.root_agent)
end

test "root_agent can hold a Definition" do
  defn = %SkillKit.Agent.Definition{
    name: "lobby",
    description: "test",
    system_prompt: "test",
    path: "/test",
    workspace: "/test"
  }
  kit = %Kit{name: "test", root_agent: defn}
  assert kit.root_agent.name == "lobby"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/kit_test.exs`
Expected: Fail — `:root_agent` not a valid key.

- [ ] **Step 3: Add the field to Kit struct**

In `lib/skill_kit/kit.ex`, add `:root_agent` to the struct and type:

```elixir
@type t :: %__MODULE__{
        name: String.t(),
        skills: [Skill.t()],
        agents: [Definition.t()],
        root_agent: Definition.t() | nil,
        metadata: map()
      }

@enforce_keys [:name]
defstruct [
  :name,
  :root_agent,
  skills: [],
  agents: [],
  metadata: %{}
]
```

- [ ] **Step 4: Run tests**

Run: `mix test`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/kit.ex test/skill_kit/kit_test.exs
git commit -m "feat(kit): add :root_agent field to Kit struct"
```

---

### Task 2: Update Backend.Filesystem — `dir:` singular + root agent detection

Change `dirs:` to `dir:`, detect root-level AGENT.md separately from nested agents.

**Files:**
- Modify: `lib/skill_kit/backend/filesystem/filesystem.ex`
- Modify: `test/skill_kit/backend/filesystem_test.exs`

- [ ] **Step 1: Write tests for `dir:` and root agent**

Create test fixtures first. Create `test/support/fixtures/skills/with_root_agent/AGENT.md`:

```markdown
---
name: root-agent
description: A root agent for testing
capabilities: bash
---
You are the root agent.
```

Create `test/support/fixtures/skills/with_root_agent/helper/AGENT.md`:

```markdown
---
name: helper
description: A subagent for testing
capabilities: bash
---
You are a helper.
```

Create `test/support/fixtures/skills/with_root_agent/my_skills/test.skill.md`:

```markdown
---
name: test
description: A test skill
---
Do the test thing.
```

Update `test/skill_kit/backend/filesystem_test.exs`:

```elixir
@root_agent_fixtures_path Path.join([
                            __DIR__,
                            "..",
                            "..",
                            "support",
                            "fixtures",
                            "skills",
                            "with_root_agent"
                          ])

describe "load_kits/1 with dir: (singular)" do
  test "loads skills and agents from a single directory" do
    assert {:ok, [kit]} = Filesystem.load_kits(dir: @valid_fixtures_path)
    skills = kit.skills
    skill_names = Enum.map(skills, & &1.name)

    assert "files:summarize" in skill_names
    assert "tools:greet" in skill_names
  end

  test "detects root AGENT.md as root_agent" do
    assert {:ok, [kit]} = Filesystem.load_kits(dir: @root_agent_fixtures_path)
    assert kit.root_agent != nil
    assert kit.root_agent.name == "root-agent"
  end

  test "nested agents go into agents list, not root_agent" do
    assert {:ok, [kit]} = Filesystem.load_kits(dir: @root_agent_fixtures_path)
    agent_names = Enum.map(kit.agents, & &1.name)
    assert "helper" in agent_names
    refute "root-agent" in agent_names
  end

  test "skills are loaded alongside root agent" do
    assert {:ok, [kit]} = Filesystem.load_kits(dir: @root_agent_fixtures_path)
    skill_names = Enum.map(kit.skills, & &1.name)
    assert Enum.any?(skill_names, &String.contains?(&1, "test"))
  end

  test "kit with no root AGENT.md has nil root_agent" do
    assert {:ok, [kit]} = Filesystem.load_kits(dir: @valid_fixtures_path)
    assert is_nil(kit.root_agent)
  end

  test "returns {:ok, []} for nonexistent directory" do
    assert {:ok, []} = Filesystem.load_kits(dir: "/nonexistent/path")
  end
end
```

Also update existing `dirs:` tests to use `dir:` — or keep them with a deprecation path. For simplicity, update all existing tests from `dirs:` to `dir:`. The existing tests pass single-element lists anyway.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/skill_kit/backend/filesystem_test.exs`
Expected: Failures — `dir:` not recognized, root_agent not set.

- [ ] **Step 3: Implement the changes**

In `lib/skill_kit/backend/filesystem/filesystem.ex`:

```elixir
@impl true
def load_kits(config) do
  case Keyword.fetch(config, :dir) do
    {:ok, dir} ->
      load_single_dir(dir)

    :error ->
      # Legacy support for dirs: (plural)
      dirs = Keyword.fetch!(config, :dirs)

      kits =
        dirs
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&load_kit/1)

      {:ok, kits}
  end
end

defp load_single_dir(dir) do
  if File.dir?(dir) do
    {:ok, [load_kit(dir)]}
  else
    {:ok, []}
  end
end
```

Update `load_kit/1` to detect root AGENT.md and make subagent discovery recursive:

```elixir
defp load_kit(dir) do
  {skills, skill_errors} = load_skills_from(dir)
  {agents, agent_errors} = load_agents_from(dir)
  {root_agent, root_errors} = load_root_agent(dir)
  errors = skill_errors ++ agent_errors ++ root_errors

  if errors != [] do
    error_summary =
      Enum.map_join(errors, ", ", fn {source, reason} ->
        "#{source}: #{inspect(reason)}"
      end)

    Logger.warning(
      "SkillKit: kit '#{Path.basename(dir)}' — #{length(errors)} skipped (#{error_summary})"
    )
  end

  %Kit{name: Path.basename(dir), skills: skills, agents: agents, root_agent: root_agent}
end

defp load_root_agent(dir) do
  root_path = Path.join(dir, "AGENT.md")

  if File.exists?(root_path) do
    case Definition.parse(root_path) do
      {:ok, agent} -> {agent, []}
      {:error, reason} -> {nil, [{"AGENT.md", reason}]}
    end
  else
    {nil, []}
  end
end
```

Update `discover_agent_files/1` to be recursive — it must find AGENT.md files at any depth, excluding the root (which is handled by `load_root_agent`):

```elixir
defp discover_agent_files(dir) do
  dir
  |> Path.join("**/AGENT.md")
  |> Path.wildcard()
  |> Enum.reject(&root_agent_path?(dir, &1))
end

defp root_agent_path?(dir, path) do
  Path.dirname(path) == dir
end
```

This mirrors how skills use `**/*.skill.md` for recursive discovery. The root AGENT.md is excluded since it's handled separately as the root agent.

- [ ] **Step 4: Run tests**

Run: `mix test`
Expected: All pass (both new `dir:` tests and legacy `dirs:` tests).

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/backend/filesystem/filesystem.ex \
  test/skill_kit/backend/filesystem_test.exs \
  test/support/fixtures/skills/with_root_agent/
git commit -m "feat(backend): add dir: (singular) option and root agent detection

Backend.Filesystem now accepts dir: for a single directory.
AGENT.md at the root of a source dir is detected as the root agent.
Nested AGENT.md files remain subagents. Legacy dirs: still supported."
```

---

### Task 3: Add `start_agent/1` — source-driven clause

The new `start_agent/1` loads kits from sources, finds the single root agent, and delegates to the existing `start_agent/2`.

**Files:**
- Modify: `lib/skill_kit.ex`
- Create: `test/skill_kit/start_agent_test.exs`

- [ ] **Step 1: Write tests**

Create `test/skill_kit/start_agent_test.exs`:

```elixir
defmodule SkillKit.StartAgentTest do
  use ExUnit.Case

  alias SkillKit.Backend.Filesystem

  @fixtures_path Path.join([__DIR__, "..", "support", "fixtures", "skills", "with_root_agent"])

  describe "start_agent/1 source-driven" do
    test "discovers and starts root agent from sources" do
      assert {:ok, agent} =
               SkillKit.start_agent(
                 sources: [{Filesystem, dir: @fixtures_path}],
                 caller: self()
               )

      assert agent.name == "root-agent"
      SkillKit.stop_agent(agent)
    end

    test "accepts :name override" do
      assert {:ok, agent} =
               SkillKit.start_agent(
                 sources: [{Filesystem, dir: @fixtures_path}],
                 name: "custom-name",
                 caller: self()
               )

      assert agent.name == "custom-name"
      SkillKit.stop_agent(agent)
    end

    test "returns error when no root agent found" do
      no_agent_path = Path.join([__DIR__, "..", "support", "fixtures", "skills", "valid"])

      assert {:error, :no_root_agent} =
               SkillKit.start_agent(
                 sources: [{Filesystem, dir: no_agent_path}],
                 caller: self()
               )
    end

    test "returns error when multiple root agents found" do
      # Two sources, each with a root agent
      assert {:error, :multiple_root_agents} =
               SkillKit.start_agent(
                 sources: [
                   {Filesystem, dir: @fixtures_path},
                   {Filesystem, dir: @fixtures_path}
                 ],
                 caller: self()
               )
    end
  end
end
```

Note: The "multiple root agents" test uses the same fixture twice. Each load returns a kit with a root_agent, so two root agents are found.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/skill_kit/start_agent_test.exs`
Expected: Fail — `start_agent/1` with keyword list doesn't match any clause.

- [ ] **Step 3: Implement start_agent/1**

In `lib/skill_kit.ex`, add a new clause before the existing `start_agent/2`:

```elixir
@doc """
Starts an agent discovered from backend sources.

Loads kits from all sources, finds the single root agent (AGENT.md at
the root of a source directory), and starts it with all co-located
skills and subagents registered.

Returns `{:error, :no_root_agent}` if no source contains a root agent.
Returns `{:error, :multiple_root_agents}` if more than one root agent is found.

## Options

  * `:sources` (required) — list of `{module, config}` backend sources
  * `:name` — override the agent name (default: from agent definition)
  * `:caller` — the pid to receive streamed events (default: `self()`)
  * `:scope` — scope for authorization and variable resolution
  * `:conversation_store` — `{module, config}` for persistence

## Examples

    {:ok, agent} = SkillKit.start_agent(
      sources: [{SkillKit.Backend.Filesystem, dir: ".skills"}],
      scope: my_scope
    )
"""
@spec start_agent(keyword()) :: {:ok, agent()} | {:error, term()}
def start_agent(opts) when is_list(opts) do
  sources = Keyword.fetch!(opts, :sources)

  kits = load_all_kits(sources)

  case extract_root_agent(kits) do
    {:ok, definition} ->
      start_agent(definition, opts)

    {:error, _} = error ->
      error
  end
end
```

Add the helper functions:

```elixir
defp load_all_kits(sources) do
  Enum.flat_map(sources, fn {mod, config} ->
    case mod.load_kits(config) do
      {:ok, kits} -> kits
      {:error, _} -> []
    end
  end)
end

defp extract_root_agent(kits) do
  root_agents =
    kits
    |> Enum.map(& &1.root_agent)
    |> Enum.reject(&is_nil/1)

  case root_agents do
    [definition] -> {:ok, definition}
    [] -> {:error, :no_root_agent}
    _ -> {:error, :multiple_root_agents}
  end
end
```

IMPORTANT: To avoid double-loading kits (once in `start_agent/1` and again in `Agent.init`), pass the pre-loaded kits through opts. Update the `start_agent/1` implementation:

```elixir
def start_agent(opts) when is_list(opts) do
  sources = Keyword.fetch!(opts, :sources)
  kits = load_all_kits(sources)

  case extract_root_agent(kits) do
    {:ok, definition} ->
      opts = Keyword.put(opts, :kits, kits)
      start_agent(definition, opts)

    {:error, _} = error ->
      error
  end
end
```

Then in `start_agent/2`, extract `:kits` from opts and include it in `agent_opts`:

```elixir
kits = Keyword.get(opts, :kits)

agent_opts = %{
  agent_name: agent_name,
  definition: definition,
  depth: 0,
  parent_name: nil,
  scope: scope,
  sources: sources,
  registry: registry_name,
  caller: caller,
  conversation_store: conversation_store,
  kits: kits
}
```

In `lib/skill_kit/agent/agent.ex`, update the `@type opts` to include `optional(:kits) => [Kit.t()] | nil`, and update `init/1` to use pre-loaded kits when available:

```elixir
kits = Map.get(opts, :kits) || load_kits_from_sources(sources)
```

IMPORTANT: Two issues need solving:

**A) Function clause conflict.** The existing `start_agent/2` has `def start_agent(definition, opts \\ [])` which generates a `start_agent/1`. The new source-driven `start_agent/1` with `when is_list(opts)` conflicts.

Fix: Remove the default from `start_agent/2` and add separate clauses:

```elixir
# Source-driven (keyword list)
def start_agent(opts) when is_list(opts) do
  ...
end

# Definition with default opts
def start_agent(%Agent.Definition{} = definition) do
  start_agent(definition, [])
end

# Definition with explicit opts
def start_agent(%Agent.Definition{} = definition, opts) do
  ...
end
```

**B) `:name` override.** `start_agent/2` must respect a `:name` option so callers (including `start_agent/1`) can override the agent name:

```elixir
def start_agent(%Agent.Definition{} = definition, opts) do
  agent_name = Keyword.get(opts, :name, definition.name)
  caller = Keyword.get(opts, :caller, self())
  ...

  agent_opts = %{
    agent_name: agent_name,
    ...
  }

  case Agent.start_link(agent_opts) do
    {:ok, sup_pid} ->
      {:ok, %AgentRef{name: agent_name, ...}}
    ...
  end
end
```

Update the `start_agent/2` doc to include `:name` in the options list.

- [ ] **Step 4: Run tests**

Run: `mix test`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit.ex test/skill_kit/start_agent_test.exs
git commit -m "feat: add source-driven start_agent/1

start_agent/1 accepts a keyword list with :sources, discovers the
root agent from loaded kits, and starts it. No manual Definition
parsing needed by callers."
```

---

### Task 4: Update Example App

Restructure `.skills/` (move lobby AGENT.md to root), update CLI to use new API.

**Files:**
- Move: `.skills/lobby/AGENT.md` → `.skills/AGENT.md`
- Modify: `examples/persona_chat/lib/persona_chat/cli.ex`

- [ ] **Step 1: Move lobby agent to root of .skills/**

```bash
cd examples/persona_chat
mv .skills/lobby/AGENT.md .skills/AGENT.md
rm -rf .skills/lobby
```

Update the workspace metadata in `.skills/AGENT.md` — since the file is now at `.skills/AGENT.md`, workspace `../..` should become `..`:

Check the current metadata workspace value and adjust so it resolves to the persona_chat project root.

- [ ] **Step 2: Update CLI to use source-driven API**

In `examples/persona_chat/lib/persona_chat/cli.ex`, update `run_lobby/2`:

```elixir
defp run_lobby(username, owner) do
  scope = PersonaChat.Scope.build(username, nil, owner: owner)

  {:ok, agent} =
    SkillKit.start_agent(
      sources: [{SkillKit.Backend.Filesystem, dir: ".skills"}],
      scope: scope
    )

  IO.puts("=== Persona Chat Lobby ===")
  IO.puts("Logged in as: #{username}#{if owner, do: " (owner)", else: ""}")
  IO.puts("Type /quit to exit.\n")

  chat_loop(agent)
  SkillKit.stop_agent(agent)
end
```

Update `run_persona_chat/3`:

```elixir
defp run_persona_chat(username, persona_name, owner) do
  persona_dir = "#{@personas_dir}/#{persona_name}"

  unless File.dir?(persona_dir) do
    IO.puts("Persona '#{persona_name}' not found. Available personas:")
    list_available_personas()
    System.halt(1)
  end

  scope = PersonaChat.Scope.build(username, persona_name, owner: owner)

  {:ok, agent} =
    SkillKit.start_agent(
      sources: [
        {SkillKit.Backend.Filesystem, dir: persona_dir},
        {SkillKit.Backend.Filesystem, dir: ".skills/memory_kit"}
      ],
      name: "#{persona_name}:#{username}",
      scope: scope,
      conversation_store:
        {SkillKit.Conversation.Store.Filesystem, path: "#{@data_dir}/conversations"}
    )

  IO.puts("=== Chatting with #{persona_name} ===")
  IO.puts("Logged in as: #{username}")
  IO.puts("Type /quit to exit.\n")

  chat_loop(agent)
  SkillKit.stop_agent(agent)
end
```

Remove `alias SkillKit.Agent.Definition` if no longer used. Update `list_available_personas` to check for directories with AGENT.md instead of using Definition.parse (or keep it — it's just for display).

- [ ] **Step 3: Verify compilation**

Run: `cd examples/persona_chat && mix compile --warnings-as-errors`
Expected: Clean compile.

- [ ] **Step 4: Run main library tests**

Run: `cd /path/to/projects/skill_kit && mix test`
Expected: All pass.

- [ ] **Step 5: Commit**

```bash
git add examples/persona_chat/
git commit -m "refactor(examples): use source-driven start_agent in persona_chat

Lobby starts from .skills/ directory with root AGENT.md. Personas
start from their own directory + memory_kit. No Definition parsing
in the CLI."
```

---

### Task 5: Run Precommit

**Files:**
- Potentially any file touched in Tasks 1-4

- [ ] **Step 1: Run full precommit pipeline**

Run: `mix precommit`
Expected: Clean — compile, format, credo, test.

- [ ] **Step 2: Fix any issues**

- [ ] **Step 3: Commit fixes if any**
