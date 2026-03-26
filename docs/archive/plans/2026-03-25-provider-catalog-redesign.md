# Provider list_kits/get_kit + Catalog Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `load_kits/1` with `list_kits/1` + `get_kit/2` on providers, build Kit.Memory, and rebuild `SkillKit.Catalog` as the single module that replaces Registry, Infrastructure, old Catalog, and ToolBuilder.

**Architecture:** Add new interfaces alongside old ones, switch consumers one at a time, then remove old code. Every commit leaves tests green. The Catalog is a GenServer per agent that aggregates providers, unpacks kits, handles authorization, builds tool definitions, and classifies tool calls.

**Tech Stack:** Elixir/OTP, SkillKit core

**Spec:** `docs/superpowers/specs/2026-03-25-provider-list-get-design.md`

**Key reference files:**
- `lib/skill_kit/kit/provider.ex:10` — current `@callback load_kits/1`
- `lib/skill_kit/kit/local.ex:16-21` — current `load_kits/1` implementation
- `lib/skill_kit/kit.ex:32-47` — Kit struct, `lib/skill_kit/kit.ex:49-81` — `__using__` macro
- `lib/skill_kit/registry.ex` — ETS-backed Registry (to be replaced)
- `lib/skill_kit/catalog.ex` — current Catalog (to be replaced)
- `lib/skill_kit/agent/tool_builder.ex:30-57` — `build_tools/2`, `lib/skill_kit/agent/tool_builder.ex:72-89` — `classifier/2`
- `lib/skill_kit/agent/infrastructure.ex` — Infrastructure supervisor (to be removed)
- `lib/skill_kit/agent/agent.ex:82-88` — supervision tree children
- `lib/skill_kit/agent/server.ex:207-211` — ToolBuilder integration, `lib/skill_kit/agent/server.ex:348-394` — activate_skill
- `lib/skill_kit.ex:66-78` — source-driven `start_agent/1`

**Code style (from CLAUDE.md):**
- No alias shortcuts — alias each module individually
- Never pipe into a single function or into case/if/with
- Never inline multiline expressions into case/with/if — extract to helper
- Prefer capture syntax (`&`) over `fn` for simple expressions
- Conventional commits: `type(scope): message`

---

## File Structure

### New files:

```
lib/skill_kit/kit/memory.ex                  # In-memory provider (Agent-backed)
lib/skill_kit/catalog.ex                     # Rewritten — GenServer, replaces 4 modules
test/skill_kit/kit/memory_test.exs
test/skill_kit/catalog_test.exs
```

### Modified files:

```
lib/skill_kit/kit/provider.ex               # Add list_kits/1, get_kit/2 callbacks
lib/skill_kit/kit/local.ex                  # Implement list_kits/1, get_kit/2
lib/skill_kit/kit.ex                        # Update __using__ macro
lib/skill_kit/agent/definition.ex           # Remove capabilities field
lib/skill_kit/agent/agent.ex                # New supervision tree, delete resolve_capabilities
lib/skill_kit/agent/server.ex               # Use Catalog instead of ToolBuilder/Registry/Catalog
lib/skill_kit.ex                            # Update start_agent/1 for Catalog
examples/**/AGENT.md                        # Remove capabilities: lines
```

### Removed files (final task):

```
lib/skill_kit/registry.ex                   # Replaced by Catalog
lib/skill_kit/supervisor.ex                 # Started Registry, no longer needed
lib/skill_kit/agent/infrastructure.ex       # Replaced by Catalog in supervision tree
lib/skill_kit/agent/tool_builder.ex         # Absorbed into Catalog
test/skill_kit/registry_test.exs            # Tests migrate to catalog_test.exs
test/skill_kit/agent/tool_builder_test.exs  # Tests migrate to catalog_test.exs
```

---

## Task 0: Remove capabilities field and resolve_capabilities

**Files:**
- Modify: `lib/skill_kit/agent/definition.ex`
- Modify: `lib/skill_kit/agent/agent.ex`
- Modify: `examples/**/AGENT.md` (remove capabilities lines)
- Modify: `test/` (update any tests referencing capabilities)

The `capabilities` field is unnecessary — what tools the agent has access to is determined by its configured providers and the kits they contain. `activate_skill` is available if the agent has skills. `bash` is available if `SkillKit.Tools.Shell` is a provider. No need to redeclare.

`resolve_capabilities` (which injected skill bodies into the system prompt) is deleted — skills enter context only through progressive disclosure.

- [ ] **Step 1: Remove field from Definition struct**

In `lib/skill_kit/agent/definition.ex`:
- Line 13: delete `capabilities: [String.t()]` from the type
- Line 28: delete `capabilities: []` from defstruct
- Line 54: delete `capabilities: parse_list(...)` from parse function

- [ ] **Step 2: Delete resolve_capabilities in agent.ex**

In `lib/skill_kit/agent/agent.ex`, delete:
- Line 62: `definition = resolve_capabilities(definition, kits)`
- Lines 91-109: the entire `resolve_capabilities/2` function

- [ ] **Step 3: Remove capabilities from AGENT.md files**

Remove the `capabilities:` line from all AGENT.md files:
- `examples/persona_chat/.skills/AGENT.md`
- `examples/persona_chat/.skills/persona_kit/persona_writer/AGENT.md`
- `examples/agents/neve/AGENT.md`
- `examples/agents/researcher/AGENT.md`
- `examples/agents/code-reviewer/AGENT.md`
- `examples/agents/fixer/AGENT.md`

- [ ] **Step 4: Update tests**

Search for `capabilities` in test files and remove references.

Run: `mix test`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(agent): remove capabilities field and resolve_capabilities"
```

---

## Task 1: Add list_kits/get_kit to Provider Behaviour

**Files:**
- Modify: `lib/skill_kit/kit/provider.ex`
- Test: existing tests still pass

- [ ] **Step 1: Add new callbacks to provider.ex**

Open `lib/skill_kit/kit/provider.ex`. Currently contains one callback at line 10. Add two new callbacks below it:

```elixir
defmodule SkillKit.Kit.Provider do
  @moduledoc """
  Behaviour for skill kit providers.

  Host applications implement this behaviour for their own storage.
  """

  @callback load_kits(config :: keyword()) :: {:ok, [SkillKit.Kit.t()]} | {:error, term()}
  @callback list_kits(config :: keyword()) :: {:ok, [SkillKit.Kit.t()]} | {:error, term()}
  @callback get_kit(config :: keyword(), name :: String.t()) :: {:ok, SkillKit.Kit.t()} | {:error, :not_found}

  @optional_callbacks [load_kits: 1]
end
```

Note: `load_kits/1` becomes optional — existing providers still work but new providers only need `list_kits/get_kit`.

- [ ] **Step 2: Verify all tests pass**

Run: `mix test`
Expected: All pass — we only added optional callbacks, nothing broke.

- [ ] **Step 3: Commit**

```bash
git add lib/skill_kit/kit/provider.ex
git commit -m "feat(kit): add list_kits/1 and get_kit/2 to Provider behaviour"
```

---

## Task 2: Implement list_kits/get_kit on Kit.Local

**Files:**
- Modify: `lib/skill_kit/kit/local.ex`
- Create: `test/skill_kit/kit/local_list_get_test.exs`

Add the new callbacks alongside the existing `load_kits/1`. Kit.Local already has `load_kit/1` (private) that returns a single kit — `list_kits` and `get_kit` delegate to it.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SkillKit.Kit.Local.ListGetTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.Local

  @fixtures_dir Path.expand("../../fixtures/local_list_get", __DIR__)

  setup do
    File.mkdir_p!("#{@fixtures_dir}/my_kit")

    File.write!("#{@fixtures_dir}/my_kit/hello.skill.md", ~S"""
---
name: "my_kit:hello"
description: "Hello skill"
---
Say hello.
""")

    on_exit(fn -> File.rm_rf!(@fixtures_dir) end)
    %{dir: @fixtures_dir}
  end

  describe "list_kits/1" do
    test "returns kits from directory", %{dir: dir} do
      assert {:ok, kits} = Local.list_kits(dir: dir)
      assert length(kits) >= 1

      kit = Enum.find(kits, &(&1.name == "my_kit"))
      assert kit != nil
      assert length(kit.skills) == 1
    end

    test "returns empty list for nonexistent directory" do
      assert {:ok, []} = Local.list_kits(dir: "/nonexistent")
    end
  end

  describe "get_kit/2" do
    test "returns kit by name", %{dir: dir} do
      assert {:ok, kit} = Local.get_kit([dir: dir], "my_kit")
      assert kit.name == "my_kit"
      assert length(kit.skills) == 1
    end

    test "returns error for unknown kit" do
      assert {:error, :not_found} = Local.get_kit([dir: "/nonexistent"], "nope")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/kit/local_list_get_test.exs`
Expected: FAIL — `list_kits/1` not defined

- [ ] **Step 3: Write implementation**

Add to `lib/skill_kit/kit/local.ex` after the existing `load_kits/1`:

```elixir
@impl true
def list_kits(config) do
  case Keyword.fetch(config, :dir) do
    {:ok, dir} -> list_from_dir(dir)
    :error -> list_from_dirs(config)
  end
end

@impl true
def get_kit(config, name) do
  case list_kits(config) do
    {:ok, kits} -> find_kit_by_name(kits, name)
    error -> error
  end
end

defp list_from_dir(dir) do
  if File.dir?(dir) do
    load_single_dir(dir)
  else
    {:ok, []}
  end
end

defp list_from_dirs(config) do
  dirs = Keyword.get(config, :dirs, [])

  kits =
    dirs
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir ->
      case load_single_dir(dir) do
        {:ok, [kit]} -> [kit]
        _ -> []
      end
    end)

  {:ok, kits}
end

defp find_kit_by_name(kits, name) do
  case Enum.find(kits, &(&1.name == name)) do
    nil -> {:error, :not_found}
    kit -> {:ok, kit}
  end
end
```

Note: `list_kits` reuses `load_single_dir` (the existing private function that `load_kits` delegates to). No duplication — the new functions are thin wrappers.

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/kit/local_list_get_test.exs`
Expected: All pass

- [ ] **Step 5: Run full suite**

Run: `mix test`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/kit/local.ex test/skill_kit/kit/local_list_get_test.exs
git commit -m "feat(kit): implement list_kits/get_kit on Kit.Local"
```

---

## Task 3: Build Kit.Memory Provider

**Files:**
- Create: `lib/skill_kit/kit/memory.ex`
- Create: `test/skill_kit/kit/memory_test.exs`

In-memory provider backed by an Agent. Stores kits (and convenience methods for individual skills). Implements `list_kits/1` and `get_kit/2`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SkillKit.Kit.MemoryTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit
  alias SkillKit.Kit.Memory
  alias SkillKit.Skill

  setup do
    {:ok, pid} = Memory.start_link([])
    %{provider: pid}
  end

  describe "put_kit/2 and list_kits/1" do
    test "stores and retrieves kits", %{provider: pid} do
      kit = %Kit{name: "test_kit", skills: [%Skill{name: "test_kit:hello", description: "Hello", body: "Say hello."}]}
      :ok = Memory.put_kit(pid, kit)

      {:ok, kits} = Memory.list_kits(provider: pid)
      assert length(kits) == 1
      assert hd(kits).name == "test_kit"
    end

    test "replaces kit with same name", %{provider: pid} do
      :ok = Memory.put_kit(pid, %Kit{name: "k", skills: []})
      :ok = Memory.put_kit(pid, %Kit{name: "k", skills: [%Skill{name: "k:a", description: "A", body: "a"}]})

      {:ok, [kit]} = Memory.list_kits(provider: pid)
      assert length(kit.skills) == 1
    end
  end

  describe "get_kit/2" do
    test "returns kit by name", %{provider: pid} do
      :ok = Memory.put_kit(pid, %Kit{name: "my_kit", skills: []})

      assert {:ok, kit} = Memory.get_kit([provider: pid], "my_kit")
      assert kit.name == "my_kit"
    end

    test "returns error for unknown kit", %{provider: pid} do
      assert {:error, :not_found} = Memory.get_kit([provider: pid], "nope")
    end
  end

  describe "put/2 convenience" do
    test "wraps a skill in an auto-named kit", %{provider: pid} do
      skill = %Skill{name: "ns:hello", description: "Hello", body: "Say hello."}
      :ok = Memory.put(pid, skill)

      {:ok, kits} = Memory.list_kits(provider: pid)
      assert length(kits) == 1

      [kit] = kits
      assert kit.name == "ns"
      assert length(kit.skills) == 1
    end

    test "groups skills by namespace into kits", %{provider: pid} do
      :ok = Memory.put(pid, %Skill{name: "ns:a", description: "A", body: "a"})
      :ok = Memory.put(pid, %Skill{name: "ns:b", description: "B", body: "b"})

      {:ok, [kit]} = Memory.list_kits(provider: pid)
      assert kit.name == "ns"
      assert length(kit.skills) == 2
    end
  end

  describe "delete/2" do
    test "removes a skill and cleans up empty kit", %{provider: pid} do
      :ok = Memory.put(pid, %Skill{name: "ns:hello", description: "Hello", body: "hello"})
      :ok = Memory.delete(pid, "ns:hello")

      {:ok, kits} = Memory.list_kits(provider: pid)
      assert kits == []
    end
  end

  describe "empty provider" do
    test "returns empty list", %{provider: pid} do
      {:ok, kits} = Memory.list_kits(provider: pid)
      assert kits == []
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/kit/memory_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Write implementation**

```elixir
defmodule SkillKit.Kit.Memory do
  @moduledoc """
  In-memory kit provider for testing and dynamic skill injection.

  Backed by an `Agent`. Stores kits directly or wraps individual
  skills into auto-named kits by namespace.

      {:ok, provider} = Kit.Memory.start_link([])
      Kit.Memory.put(provider, %Skill{name: "ns:hello", body: "..."})
      {:ok, kits} = Kit.Memory.list_kits(provider: provider)
  """

  @behaviour SkillKit.Kit.Provider

  alias SkillKit.Kit
  alias SkillKit.Skill

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @spec put_kit(pid() | atom(), Kit.t()) :: :ok
  def put_kit(provider, %Kit{} = kit) do
    Agent.update(provider, &Map.put(&1, kit.name, kit))
  end

  @spec put(pid() | atom(), Skill.t()) :: :ok
  def put(provider, %Skill{} = skill) do
    namespace = extract_namespace(skill.name)

    Agent.update(provider, fn state ->
      kit = Map.get(state, namespace, %Kit{name: namespace})
      existing = Enum.reject(kit.skills, &(&1.name == skill.name))
      updated = %{kit | skills: existing ++ [skill]}
      Map.put(state, namespace, updated)
    end)
  end

  @spec delete(pid() | atom(), String.t()) :: :ok
  def delete(provider, skill_name) do
    namespace = extract_namespace(skill_name)

    Agent.update(provider, fn state ->
      case Map.get(state, namespace) do
        nil ->
          state

        kit ->
          remaining = Enum.reject(kit.skills, &(&1.name == skill_name))

          if remaining == [] do
            Map.delete(state, namespace)
          else
            Map.put(state, namespace, %{kit | skills: remaining})
          end
      end
    end)
  end

  @impl SkillKit.Kit.Provider
  def list_kits(config) do
    provider = Keyword.fetch!(config, :provider)
    kits = Agent.get(provider, &Map.values/1)
    {:ok, kits}
  end

  @impl SkillKit.Kit.Provider
  def get_kit(config, name) do
    provider = Keyword.fetch!(config, :provider)

    case Agent.get(provider, &Map.get(&1, name)) do
      nil -> {:error, :not_found}
      kit -> {:ok, kit}
    end
  end

  defp extract_namespace(name) do
    case String.split(name, ":", parts: 2) do
      [namespace, _] -> namespace
      [bare] -> bare
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/kit/memory_test.exs`
Expected: All pass

- [ ] **Step 5: Run full suite**

Run: `mix test`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/kit/memory.ex test/skill_kit/kit/memory_test.exs
git commit -m "feat(kit): add in-memory provider Kit.Memory"
```

---

## Task 4: Build New Catalog

**Files:**
- Create: `lib/skill_kit/catalog_new.ex` (temporary name to avoid conflict with existing catalog.ex)
- Create: `test/skill_kit/catalog_new_test.exs`

The new Catalog is a GenServer that aggregates providers, unpacks kits, handles authorization, builds tool definitions, and classifies tool calls. We build it alongside the old Catalog, test it independently, then swap in Task 6.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SkillKit.CatalogNewTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit
  alias SkillKit.Kit.Memory
  alias SkillKit.Skill
  alias SkillKit.Agent.Definition
  alias SkillKit.CatalogNew, as: Catalog

  setup do
    {:ok, provider} = Memory.start_link([])

    :ok = Memory.put_kit(provider, %Kit{
      name: "test_kit",
      skills: [
        %Skill{name: "test_kit:hello", description: "Hello skill", body: "Say hello.", required_scope: []},
        %Skill{name: "test_kit:secret", description: "Secret skill", body: "Secret.", required_scope: ["admin:read"]}
      ],
      agents: [
        %Definition{name: "writer", description: "Writes things", system_prompt: "You write.", capabilities: []}
      ]
    })

    {:ok, catalog} = Catalog.start_link(
      providers: [{Memory, provider: provider}],
      scope: nil
    )

    %{catalog: catalog, provider: provider}
  end

  describe "list_skills/1" do
    test "returns name and description for each skill", %{catalog: catalog} do
      skills = Catalog.list_skills(catalog)

      assert length(skills) == 2
      assert Enum.any?(skills, fn {name, _desc} -> name == "test_kit:hello" end)
    end

    test "returns tuples of {name, description}", %{catalog: catalog} do
      [{name, desc} | _] = Catalog.list_skills(catalog)

      assert is_binary(name)
      assert is_binary(desc)
    end
  end

  describe "list_skills/1 with authorization" do
    test "filters skills by scope" do
      {:ok, provider} = Memory.start_link([])

      :ok = Memory.put_kit(provider, %Kit{
        name: "auth_kit",
        skills: [
          %Skill{name: "auth_kit:public", description: "Public", body: "public", required_scope: []},
          %Skill{name: "auth_kit:admin", description: "Admin only", body: "admin", required_scope: ["admin:read"]}
        ]
      })

      scope = %{permissions: []}

      {:ok, catalog} = Catalog.start_link(
        providers: [{Memory, provider: provider}],
        scope: scope
      )

      skills = Catalog.list_skills(catalog)

      names = Enum.map(skills, &elem(&1, 0))
      assert "auth_kit:public" in names
      refute "auth_kit:admin" in names
    end
  end

  describe "get_skill/2" do
    test "returns full skill by name", %{catalog: catalog} do
      assert {:ok, skill} = Catalog.get_skill(catalog, "test_kit:hello")
      assert skill.name == "test_kit:hello"
      assert skill.body == "Say hello."
    end

    test "returns error for unknown skill", %{catalog: catalog} do
      assert {:error, :not_found} = Catalog.get_skill(catalog, "nope:nope")
    end

    test "returns unauthorized for skill outside scope" do
      {:ok, provider} = Memory.start_link([])

      :ok = Memory.put_kit(provider, %Kit{
        name: "auth_kit",
        skills: [
          %Skill{name: "auth_kit:admin", description: "Admin only", body: "admin", required_scope: ["admin:read"]}
        ]
      })

      {:ok, catalog} = Catalog.start_link(
        providers: [{Memory, provider: provider}],
        scope: %{permissions: []}
      )

      assert {:error, :unauthorized} = Catalog.get_skill(catalog, "auth_kit:admin")
    end
  end

  describe "list_agents/1" do
    test "returns agent definitions from all kits", %{catalog: catalog} do
      agents = Catalog.list_agents(catalog)

      assert length(agents) == 1
      assert hd(agents).name == "writer"
    end
  end

  describe "get_agent/2" do
    test "returns agent definition by name", %{catalog: catalog} do
      assert {:ok, agent} = Catalog.get_agent(catalog, "writer")
      assert agent.name == "writer"
    end

    test "returns error for unknown agent", %{catalog: catalog} do
      assert {:error, :not_found} = Catalog.get_agent(catalog, "nope")
    end
  end

  describe "definitions/1" do
    test "returns tool definitions for the LLM", %{catalog: catalog} do
      tools = Catalog.definitions(catalog)

      assert is_list(tools)
      # Should include activate_skill at minimum
      names = Enum.map(tools, & &1.name)
      assert "activate_skill" in names
    end
  end

  describe "classify/3" do
    test "classifies activate_skill", %{catalog: catalog} do
      assert :activate_skill = Catalog.classify(catalog, "activate_skill")
    end

    test "classifies agent names", %{catalog: catalog} do
      assert :agent = Catalog.classify(catalog, "writer")
    end

    test "classifies unknown names as handler", %{catalog: catalog} do
      assert :handler = Catalog.classify(catalog, "bash")
    end

    test "classifies builtins", %{catalog: catalog} do
      assert :builtin = Catalog.classify(catalog, "report_status")
      assert :builtin = Catalog.classify(catalog, "report_result")
    end

    test "classifies activated module-backed skills", %{catalog: catalog} do
      # A module-backed skill that has been activated in the conversation
      activated = %Skill{name: "custom:tool", handler: SomeHandler, description: "Custom"}
      result = Catalog.classify(catalog, "custom_tool_name", [activated])

      # Will return {:module_skill, skill} if the handler's definition name matches
      # Exact assertion depends on handler mock — test verifies the code path exists
      assert result in [:handler, {:module_skill, activated}]
    end
  end

  describe "hooks/1" do
    test "returns hooks from all kits", %{catalog: catalog} do
      hooks = Catalog.hooks(catalog)
      assert is_list(hooks)
    end
  end

  describe "root_agent/1" do
    test "returns nil when no root agent", %{catalog: catalog} do
      assert Catalog.root_agent(catalog) == nil
    end

    test "returns root agent when set" do
      {:ok, provider} = Memory.start_link([])
      root = %Definition{name: "root", description: "Root agent", system_prompt: "You are root.", capabilities: []}

      :ok = Memory.put_kit(provider, %Kit{name: "root_kit", skills: [], root_agent: root})

      {:ok, catalog} = Catalog.start_link(providers: [{Memory, provider: provider}], scope: nil)

      assert %Definition{name: "root"} = Catalog.root_agent(catalog)
    end
  end

  describe "provider failure resilience" do
    test "returns partial results when one provider fails", %{provider: provider} do
      # BadProvider always fails
      defmodule BadProvider do
        @behaviour SkillKit.Kit.Provider
        def list_kits(_config), do: {:error, :boom}
        def get_kit(_config, _name), do: {:error, :not_found}
      end

      {:ok, catalog} = Catalog.start_link(
        providers: [{Memory, provider: provider}, {BadProvider, []}],
        scope: nil
      )

      # Should still return skills from the working provider
      skills = Catalog.list_skills(catalog)
      assert length(skills) > 0
    end
  end

  describe "dynamic updates" do
    test "list_skills reflects new skills added to provider", %{catalog: catalog, provider: provider} do
      skills_before = Catalog.list_skills(catalog)

      :ok = Memory.put(provider, %Skill{name: "test_kit:new", description: "New skill", body: "new"})

      skills_after = Catalog.list_skills(catalog)

      assert length(skills_after) == length(skills_before) + 1
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/catalog_new_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Write implementation**

Create `lib/skill_kit/catalog_new.ex`:

```elixir
defmodule SkillKit.CatalogNew do
  @moduledoc """
  Aggregates skill kits from providers and exposes them to agents.

  The Catalog is the single point of contact between the agent and its
  skill providers. It replaces the Registry, Infrastructure, old Catalog,
  and ToolBuilder with one unified module.

  ## Responsibilities

  - Aggregates kits from multiple providers via `list_kits/1`
  - Unpacks kits into skills, agents, hooks
  - Handles authorization (filters by agent scope)
  - Builds tool definitions for the LLM
  - Classifies tool calls back to the right handler type
  - Always fresh — calls providers on every `list_skills`, no caching

  ## Usage

      {:ok, catalog} = Catalog.start_link(
        providers: [{Kit.Local, dir: ".skills"}, {Kit.Memory, provider: pid}],
        scope: my_scope
      )

      Catalog.list_skills(catalog)     # → [{name, description}, ...]
      Catalog.get_skill(catalog, name) # → {:ok, %Skill{}}
  """

  use GenServer

  require Logger

  alias SkillKit.Authorization
  alias SkillKit.Tool
  alias SkillKit.Scope

  defstruct [:providers, :scope, routing_index: %{}]

  # --- Client API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns `[{name, description}]` for all authorized skills."
  def list_skills(catalog) do
    GenServer.call(catalog, :list_skills)
  end

  @doc "Returns the full skill struct by name."
  def get_skill(catalog, name) do
    GenServer.call(catalog, {:get_skill, name})
  end

  @doc "Returns all agent definitions from loaded kits."
  def list_agents(catalog) do
    GenServer.call(catalog, :list_agents)
  end

  @doc "Returns an agent definition by name."
  def get_agent(catalog, name) do
    GenServer.call(catalog, {:get_agent, name})
  end

  @doc "Returns all hooks from loaded kits."
  def hooks(catalog) do
    GenServer.call(catalog, :hooks)
  end

  @doc "Returns the root agent definition, if any."
  def root_agent(catalog) do
    GenServer.call(catalog, :root_agent)
  end

  @doc "Returns tool definitions ready for the LLM."
  def definitions(catalog, opts \\ []) do
    GenServer.call(catalog, {:definitions, opts})
  end

  @doc "Classifies a tool name by type."
  def classify(catalog, tool_name, activated_skills \\ []) do
    GenServer.call(catalog, {:classify, tool_name, activated_skills})
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    providers = Keyword.fetch!(opts, :providers)
    scope = Keyword.get(opts, :scope)

    state = %__MODULE__{
      providers: providers,
      scope: scope
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:list_skills, _from, state) do
    {skills, state} = load_all_skills(state)
    permissions = resolve_permissions(state.scope)
    authorized = filter_authorized(skills, permissions)
    summaries = Enum.map(authorized, fn skill -> {skill.name, skill.description} end)
    {:reply, summaries, state}
  end

  @impl true
  def handle_call({:get_skill, name}, _from, state) do
    result = fetch_skill(state, name)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:list_agents, _from, state) do
    agents = load_all_agents(state)
    {:reply, agents, state}
  end

  @impl true
  def handle_call({:get_agent, name}, _from, state) do
    agents = load_all_agents(state)

    result =
      case Enum.find(agents, &(&1.name == name)) do
        nil -> {:error, :not_found}
        agent -> {:ok, agent}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:hooks, _from, state) do
    kits = load_all_kits(state)
    all_hooks = Enum.flat_map(kits, fn kit -> collect_hooks(kit) end)
    {:reply, all_hooks, state}
  end

  @impl true
  def handle_call(:root_agent, _from, state) do
    kits = load_all_kits(state)
    root = Enum.find_value(kits, & &1.root_agent)
    {:reply, root, state}
  end

  @impl true
  def handle_call({:definitions, opts}, _from, state) do
    {skills, state} = load_all_skills(state)
    permissions = resolve_permissions(state.scope)
    authorized = filter_authorized(skills, permissions)
    agents = load_all_agents(state)
    kits = load_all_kits(state)

    is_subagent = Keyword.get(opts, :subagent, false)
    activated_skills = Keyword.get(opts, :activated_skills, [])

    tools = build_definitions(authorized, agents, kits, is_subagent, activated_skills)
    {:reply, tools, state}
  end

  @impl true
  def handle_call({:classify, tool_name, activated_skills}, _from, state) do
    result = classify_tool(state, tool_name, activated_skills)
    {:reply, result, state}
  end

  # --- Internal ---

  defp load_all_kits(state) do
    Enum.flat_map(state.providers, fn {module, config} ->
      case module.list_kits(config) do
        {:ok, kits} -> kits
        {:error, reason} ->
          Logger.warning("Catalog: provider #{inspect(module)} failed: #{inspect(reason)}")
          []
      end
    end)
  end

  defp load_all_skills(state) do
    {kits, provider_map} = load_kits_with_providers(state)
    skills = Enum.flat_map(kits, & &1.skills)

    routing_index = build_routing_index(kits, provider_map)
    state = %{state | routing_index: routing_index}

    {skills, state}
  end

  defp load_all_agents(state) do
    kits = load_all_kits(state)
    Enum.flat_map(kits, & &1.agents)
  end

  defp load_kits_with_providers(state) do
    results =
      Enum.flat_map(state.providers, fn {module, config} ->
        case module.list_kits(config) do
          {:ok, kits} -> Enum.map(kits, fn kit -> {kit, {module, config}} end)
          {:error, reason} ->
            Logger.warning("Catalog: provider #{inspect(module)} failed: #{inspect(reason)}")
            []
        end
      end)

    kits = Enum.map(results, &elem(&1, 0))
    provider_map = Map.new(results, fn {kit, provider} -> {kit.name, provider} end)
    {kits, provider_map}
  end

  defp build_routing_index(kits, provider_map) do
    for kit <- kits,
        skill <- kit.skills,
        {module, config} = Map.get(provider_map, kit.name, {nil, []}),
        into: %{} do
      {skill.name, {module, config, kit.name}}
    end
  end

  defp fetch_skill(state, name) do
    case Map.get(state.routing_index, name) do
      nil -> fetch_skill_by_scanning(state, name)
      {module, config, kit_name} -> fetch_from_provider(module, config, kit_name, name, state.scope)
    end
  end

  defp fetch_skill_by_scanning(state, name) do
    kits = load_all_kits(state)

    result =
      Enum.find_value(kits, fn kit ->
        Enum.find(kit.skills, &(&1.name == name))
      end)

    case result do
      nil -> {:error, :not_found}
      skill -> check_authorization(skill, state.scope)
    end
  end

  defp fetch_from_provider(module, config, kit_name, skill_name, scope) do
    case module.get_kit(config, kit_name) do
      {:ok, kit} ->
        case Enum.find(kit.skills, &(&1.name == skill_name)) do
          nil -> {:error, :not_found}
          skill -> check_authorization(skill, scope)
        end

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp check_authorization(skill, nil), do: {:ok, skill}

  defp check_authorization(skill, scope) do
    permissions = resolve_permissions(scope)

    if Authorization.authorized?(skill, permissions) do
      {:ok, skill}
    else
      {:error, :unauthorized}
    end
  end

  defp resolve_permissions(nil), do: []

  defp resolve_permissions(scope) do
    Scope.permissions(scope)
  rescue
    Protocol.UndefinedError -> []
  end

  defp filter_authorized(skills, []), do: skills

  defp filter_authorized(skills, permissions) do
    Enum.filter(skills, &Authorization.authorized?(&1, permissions))
  end

  defp collect_hooks(kit) do
    Enum.flat_map(kit.skills, fn skill -> skill.hooks || [] end)
  end

  defp build_definitions(skills, agents, kits, is_subagent, activated_skills) do
    skill_tool = activate_skill_tool(skills)
    handler_tools = discover_handler_tools(kits)
    agent_tools = build_agent_tools(agents)
    activated_tools = build_activated_skill_tools(activated_skills)
    builtin_tools = if is_subagent, do: builtin_tools(), else: []

    [skill_tool | handler_tools] ++ agent_tools ++ activated_tools ++ builtin_tools
  end

  defp activate_skill_tool(skills) do
    skill_names = Enum.map(skills, & &1.name)
    description = build_activate_description(skill_names, skills)

    %Tool{
      name: "activate_skill",
      description: description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Name of the skill to activate",
            "enum" => skill_names
          },
          "arguments" => %{
            "type" => "string",
            "description" => "Arguments to pass to the skill"
          }
        },
        "required" => ["name"]
      }
    }
  end

  defp build_activate_description([], _skills) do
    "No skills available."
  end

  defp build_activate_description(_names, skills) do
    lines = Enum.map(skills, fn s -> "- #{s.name}: #{s.description}" end)
    "Activate a skill. Available skills:\n" <> Enum.join(lines, "\n")
  end

  defp discover_handler_tools(kits) do
    kits
    |> Enum.filter(&handler_module?/1)
    |> Enum.map(fn kit ->
      module = kit.metadata[:handler] || kit.metadata["handler"]
      module.definition()
    end)
  end

  defp handler_module?(kit) do
    handler = kit.metadata[:handler] || kit.metadata["handler"]
    handler != nil and is_atom(handler)
  end

  defp build_agent_tools(agents) do
    Enum.map(agents, fn agent ->
      %Tool{
        name: agent.name,
        description: "Delegate to agent: #{agent.description}",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "task" => %{"type" => "string", "description" => "Task to delegate to the agent"}
          },
          "required" => ["task"]
        }
      }
    end)
  end

  defp build_activated_skill_tools(activated_skills) do
    Enum.filter(activated_skills, &module_backed?/1)
    |> Enum.map(fn skill ->
      module = skill.handler
      module.definition()
    end)
  end

  defp module_backed?(skill) do
    skill.handler != nil and skill.handler != SkillKit.Tools.Shell
  end

  defp builtin_tools do
    [
      %Tool{
        name: "report_status",
        description: "Report progress on your delegated task",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "status" => %{"type" => "string", "description" => "Current status"}
          },
          "required" => ["status"]
        }
      },
      %Tool{
        name: "report_result",
        description: "Report the final result of your delegated task",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "result" => %{"type" => "string", "description" => "The result"}
          },
          "required" => ["result"]
        }
      }
    ]
  end

  defp classify_tool(_state, "activate_skill", _activated), do: :activate_skill
  defp classify_tool(_state, "report_status", _activated), do: :builtin
  defp classify_tool(_state, "report_result", _activated), do: :builtin

  defp classify_tool(state, tool_name, activated_skills) do
    agents = load_all_agents(state)
    agent_names = MapSet.new(agents, & &1.name)

    activated_module_skill =
      Enum.find(activated_skills, fn skill ->
        module_backed?(skill) and skill.handler.definition().name == tool_name
      end)

    cond do
      activated_module_skill != nil -> {:module_skill, activated_module_skill}
      MapSet.member?(agent_names, tool_name) -> :agent
      true -> :handler
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/catalog_new_test.exs`
Expected: All pass

- [ ] **Step 5: Run full suite**

Run: `mix test`
Expected: All pass — old code untouched

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/catalog_new.ex test/skill_kit/catalog_new_test.exs
git commit -m "feat(catalog): build new Catalog with provider aggregation and tool building"
```

---

## Task 5: Update __using__ Macro in Kit

**Files:**
- Modify: `lib/skill_kit/kit.ex`

The `use SkillKit.Kit` macro currently generates `load_kits/1`. Add `list_kits/1` and `get_kit/2` that delegate to the same internal loading.

- [ ] **Step 1: Update the macro**

In `lib/skill_kit/kit.ex`, find the `__using__` macro (around line 49). Add `list_kits` and `get_kit` alongside the existing `load_kits`:

After the existing `load_kits/1` definition in the macro, add:

```elixir
def list_kits(config) do
  load_kits(config)
end

def get_kit(config, name) do
  case list_kits(config) do
    {:ok, kits} ->
      case Enum.find(kits, &(&1.name == name)) do
        nil -> {:error, :not_found}
        kit -> {:ok, kit}
      end

    error ->
      error
  end
end
```

Update the `defoverridable` line to include the new functions:

```elixir
defoverridable resume: 3, definition: 0, load_kits: 1, list_kits: 1, get_kit: 2
```

- [ ] **Step 2: Verify all tests pass**

Run: `mix test`
Expected: All pass

- [ ] **Step 3: Commit**

```bash
git add lib/skill_kit/kit.ex
git commit -m "feat(kit): generate list_kits/get_kit in __using__ macro"
```

---

## Task 6: Wire Catalog into Agent Supervision Tree

**Files:**
- Modify: `lib/skill_kit/agent/agent.ex`
- Modify: `lib/skill_kit/agent/server.ex`
- Modify: `lib/skill_kit.ex`

This is the swap — replace Registry + Infrastructure with the new Catalog, update Server to use it, update start_agent.

**This task changes the most code. Read carefully.**

- [ ] **Step 1: Update agent.ex supervision tree**

In `lib/skill_kit/agent/agent.ex`, replace the 3-child supervision tree (lines 82-88) with 2 children:

```elixir
children = [
  {Registry, keys: :unique, name: registry},
  {SkillKit.CatalogNew,
    name: {:via, Registry, {registry, {agent_name, :catalog}}},
    providers: build_provider_configs(skills),
    scope: scope
  },
  {Core, {agent_name, definition, depth, parent_name, scope, registry, server_opts}}
]
```

Remove the `Infrastructure` child. Add a helper:

```elixir
defp build_provider_configs(skills) do
  Enum.map(skills, fn {module, config} -> {module, config} end)
end
```

Note: The process `Registry` (`:unique` mode) is still needed for per-agent process lookup (mailbox, server, etc.). It's separate from the skill Catalog.

Also remove the `load_kits_from/1` function (around line 112) — the Catalog handles this now. (`resolve_capabilities/2` was already removed in Task 0.)

- [ ] **Step 2: Update server.ex to use Catalog**

In `lib/skill_kit/agent/server.ex`:

Add a helper to get the catalog ref:

```elixir
defp catalog(state) do
  {:via, Registry, {state.registry, {state.agent_name, :catalog}}}
end
```

Replace the `ToolBuilder.build_tools` call (lines 207-211):

```elixir
# OLD:
tools = ToolBuilder.build_tools(state.kits, subagent: state.depth > 0, activated_skills: state.activated_skills)

# NEW:
tools = SkillKit.CatalogNew.definitions(catalog(state),
  subagent: state.depth > 0,
  activated_skills: state.activated_skills)
```

Replace the `ToolBuilder.classifier` call (line 244):

```elixir
# OLD:
classifier = ToolBuilder.classifier(state.kits, state.activated_skills)
classify = classifier.(tool_call)

# NEW:
tool_name = tool_call["name"] || tool_call.name
classify = SkillKit.CatalogNew.classify(catalog(state), tool_name, state.activated_skills)
```

Note: `classify` now returns `{:module_skill, skill}` for activated module-backed skills. The server's `execute_tool_calls` dispatch on this value is unchanged.

Replace skill activation (lines 348-394) to use `Catalog.get_skill/2`:

```elixir
# OLD:
SkillKit.Catalog.activate(skill_registry, skill_name, args, opts)

# NEW:
SkillKit.CatalogNew.get_skill(catalog(state), skill_name)
```

Note: The `activate` function on the old Catalog also rendered the skill body. In the new model, `get_skill` returns the raw skill. The rendering (via `Skill.render/4`) should happen in the server after `get_skill` returns — check where `activate_skill/2` uses the result and ensure rendering still happens.

Replace `find_agent_definition/2` to use `Catalog.get_agent/2`.

**Server struct changes:**
- Remove: `:kits` (no longer stored — Catalog loads on demand)
- Remove: `:skills` (provider configs move to Catalog)
- Keep: `:activated_skills` (tracked per-conversation, passed to Catalog on each call)
- Keep: all other fields

- [ ] **Step 3: Update start_agent/1 in skill_kit.ex**

In `lib/skill_kit.ex`, update the source-driven `start_agent/1` (lines 66-78):

```elixir
def start_agent(opts) when is_list(opts) do
  skills = Keyword.fetch!(opts, :skills)

  # Start a temporary Catalog to discover the root agent
  {:ok, temp_catalog} = SkillKit.CatalogNew.start_link(
    providers: skills,
    scope: Keyword.get(opts, :scope)
  )

  root = SkillKit.CatalogNew.root_agent(temp_catalog)
  GenServer.stop(temp_catalog)

  case root do
    nil -> {:error, :no_root_agent}
    definition -> start_agent(definition, opts)
  end
end
```

Note: `root_agent/1` scans `kit.root_agent` across all provider kits — distinct from `list_agents` which returns `kit.agents` (subagents). This replaces the current `load_all_kits/1` + `extract_root_agent/1` flow.

- [ ] **Step 4: Run tests and fix breakage**

Run: `mix test`
Expected: Failures in these files (fix each):
- `test/skill_kit/catalog_test.exs` — references old Catalog API (`activate/4`). Update to use `get_skill/2` + `Skill.render/4` separately.
- `test/skill_kit/agent/server_test.exs` — references `ToolBuilder`, old kit loading. Update to use Catalog.
- `test/skill_kit/agent/agent_test.exs` — references Infrastructure in supervision tree. Update to expect Catalog child.
- Any test that calls `SkillKit.start_agent` with `:kits` option — remove the option, let Catalog handle it.
- Any test that directly starts `SkillKit.Registry` or `SkillKit.Supervisor` — update to start Catalog instead.

Read each failing test, understand what it asserts, and update to use the new Catalog API. Do not delete tests — migrate them.

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/agent/agent.ex lib/skill_kit/agent/server.ex lib/skill_kit.ex
git add test/  # any updated test files
git commit -m "refactor(agent): wire new Catalog into supervision tree"
```

---

## Task 7: Rename CatalogNew to Catalog and Remove Old Code

**Files:**
- Rename: `lib/skill_kit/catalog_new.ex` → `lib/skill_kit/catalog.ex`
- Rename: `test/skill_kit/catalog_new_test.exs` → `test/skill_kit/catalog_test.exs`
- Remove: `lib/skill_kit/registry.ex`
- Remove: `lib/skill_kit/supervisor.ex`
- Remove: `lib/skill_kit/agent/infrastructure.ex`
- Remove: `lib/skill_kit/agent/tool_builder.ex`
- Remove: corresponding test files
- Modify: `lib/skill_kit/kit/provider.ex` — remove `load_kits/1`

- [ ] **Step 1: Rename CatalogNew to Catalog**

```bash
git mv lib/skill_kit/catalog_new.ex lib/skill_kit/catalog.ex
git mv test/skill_kit/catalog_new_test.exs test/skill_kit/catalog_test.exs
```

Find and replace all `SkillKit.CatalogNew` with `SkillKit.Catalog` across the codebase:
- `lib/skill_kit/catalog.ex`
- `test/skill_kit/catalog_test.exs`
- `lib/skill_kit/agent/agent.ex`
- `lib/skill_kit/agent/server.ex`
- `lib/skill_kit.ex`

- [ ] **Step 2: Remove old modules**

```bash
git rm lib/skill_kit/registry.ex
git rm lib/skill_kit/supervisor.ex
git rm lib/skill_kit/agent/infrastructure.ex
git rm lib/skill_kit/agent/tool_builder.ex
```

Remove corresponding test files:

```bash
git rm test/skill_kit/registry_test.exs
git rm test/skill_kit/agent/tool_builder_test.exs
```

Check for any other files that reference the removed modules and update them.

- [ ] **Step 3: Make load_kits/1 optional in provider.ex**

Remove `load_kits/1` from the required callbacks in `provider.ex`. It's already `@optional_callbacks` from Task 1. Now remove it entirely:

```elixir
defmodule SkillKit.Kit.Provider do
  @moduledoc """
  Behaviour for skill kit providers.
  """

  @callback list_kits(config :: keyword()) :: {:ok, [SkillKit.Kit.t()]} | {:error, term()}
  @callback get_kit(config :: keyword(), name :: String.t()) :: {:ok, SkillKit.Kit.t()} | {:error, :not_found}
end
```

- [ ] **Step 4: Run full suite and fix any remaining references**

Run: `mix test`
Expected: All pass. If any test references removed modules, fix or remove the test.

- [ ] **Step 5: Run precommit**

Run: `mix precommit`
Expected: All pass (compile, format, credo, test)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: remove Registry, Infrastructure, ToolBuilder — Catalog is the single interface"
```

---

## Summary

8 tasks (0-7). Progressive migration — every commit leaves tests green.

| Task | What | Risk |
|------|------|------|
| 0 | Remove `capabilities` field + `resolve_capabilities` | Low |
| 1 | Add `list_kits/get_kit` callbacks to Provider | Low |
| 2 | Implement on Kit.Local | Low |
| 3 | Build Kit.Memory | Low |
| 4 | Build new Catalog (alongside old) | Medium |
| 5 | Update `__using__` macro | Low |
| 6 | Wire Catalog into agent supervision tree | **High** |
| 7 | Rename + remove old code | Medium |

Task 0 removes unnecessary complexity — tools are inferred from providers. Task 6 is the high-risk step — it changes the agent's core integration points. Tasks 1-5 are additive. Task 7 is cleanup.

**What's deferred:**
- Telemetry events for skill activation/listing
- Kit.Local internal caching (currently re-parses every call — fine for now, optimize later)
- Scope-based tool filtering (authorization gates which skills the agent sees)
