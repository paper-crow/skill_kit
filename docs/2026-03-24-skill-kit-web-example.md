# SkillKit.Web — Continuous Codegen from Skills

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a codegen system where `.skill.md` files define routes, a SkillKit agent continuously generates Phoenix code from those skills, tests gate every change, and hot-reload puts it live. The generated code runs at the endpoint — not a plug, not a runtime interpreter.

**Architecture:** A GenServer (`SkillKit.Web.Codegen`) loads skills, tracks content hashes and TTL. When triggered (hash change, TTL expiry, or exception signal), it spawns a SkillKit agent that reads the skill body and generates a Phoenix module. The module is compiled in memory, tests run, and if they pass, the module is hot-reloaded into the running app. The generated `.ex` files are written to `lib/generated/` for committing.

**Tech Stack:** SkillKit (agent runtime), Phoenix, `Code.purge/1` + `Code.load_binary/3` for hot-reload

**Spec:** `docs/superpowers/specs/2026-03-24-skill-kit-web-design.md`

**Key reference files:**
- `lib/skill_kit.ex` — `start_agent/1`, `send_message/2`, `send_message_sync/3`
- `lib/skill_kit/kit/provider.ex` — `@callback load_kits(config :: keyword())`
- `lib/skill_kit/kit/local.ex` — filesystem provider, `load_kits(dir: path)`
- `lib/skill_kit/skill.ex` — Skill struct: `:name`, `:body`, `:description`, `:location`, `:metadata`
- `lib/skill_kit/agent/server.ex` — agent loop, event streaming

**Code style (from CLAUDE.md):**
- No alias shortcuts — alias each module individually
- Never pipe into a single function or into case/if/with
- Never inline multiline expressions into case/with/if — extract to helper
- Prefer capture syntax (`&`) over `fn` for simple expressions
- Conventional commits: `type(scope): message`

---

## File Structure

### New files in core library:

```
lib/skill_kit/kit/
└── memory.ex                       # In-memory skill provider (Agent-backed)

lib/skill_kit/web/
├── codegen.ex                      # GenServer: tracks skills, triggers codegen cycles
├── codegen/
│   ├── generator.ex                # Spawns SkillKit agent to generate Phoenix code
│   ├── compiler.ex                 # Compiles generated code in memory, runs tests
│   └── loader.ex                   # Hot-reloads modules via Code.purge/Code.load_binary
└── skill_index.ex                  # Maps skill paths to routes, tracks hashes + TTL

test/skill_kit/kit/
└── memory_test.exs

test/skill_kit/web/
├── codegen_test.exs
├── codegen/
│   ├── generator_test.exs
│   ├── compiler_test.exs
│   └── loader_test.exs
└── skill_index_test.exs
```

### Example app:

```
examples/skill_kit_web/
├── mix.exs
├── config/
│   ├── config.exs
│   └── dev.exs
├── lib/skill_kit_web/
│   ├── application.ex              # Starts Codegen as child
│   ├── endpoint.ex
│   └── router.ex                   # Routes point to generated modules
├── .skills/
│   ├── _admin/
│   │   └── dashboard.skill.md
│   └── app/
│       └── hello.skill.md
└── lib/generated/                  # Codegen output — committed to repo
```

---

## Task 0: In-Memory Skill Provider

**Files:**
- Create: `lib/skill_kit/kit/memory.ex`
- Create: `test/skill_kit/kit/memory_test.exs`

An Agent-backed provider that implements `Kit.Provider`. Tests push skills into it instead of writing to disk. Lives in the core library — useful for any SkillKit consumer's tests.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SkillKit.Kit.MemoryTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.Memory
  alias SkillKit.Skill

  setup do
    {:ok, pid} = Memory.start_link([])
    %{provider: pid}
  end

  describe "put/2 and load_kits/1" do
    test "stores and retrieves skills", %{provider: pid} do
      skill = %Skill{
        name: "hello",
        description: "Hello page",
        body: "Render a hello page.",
        location: "/app/hello.skill.md"
      }

      :ok = Memory.put(pid, skill)
      {:ok, [kit]} = Memory.load_kits(provider: pid)

      assert length(kit.skills) == 1
      assert hd(kit.skills).name == "hello"
    end

    test "stores multiple skills", %{provider: pid} do
      :ok = Memory.put(pid, %Skill{name: "a", description: "A", body: "A", location: "/a.skill.md"})
      :ok = Memory.put(pid, %Skill{name: "b", description: "B", body: "B", location: "/b.skill.md"})

      {:ok, [kit]} = Memory.load_kits(provider: pid)
      assert length(kit.skills) == 2
    end

    test "replaces skill with same name", %{provider: pid} do
      :ok = Memory.put(pid, %Skill{name: "hello", description: "v1", body: "v1", location: "/hello.skill.md"})
      :ok = Memory.put(pid, %Skill{name: "hello", description: "v2", body: "v2", location: "/hello.skill.md"})

      {:ok, [kit]} = Memory.load_kits(provider: pid)
      assert length(kit.skills) == 1
      assert hd(kit.skills).description == "v2"
    end
  end

  describe "delete/2" do
    test "removes a skill by name", %{provider: pid} do
      :ok = Memory.put(pid, %Skill{name: "hello", description: "Hello", body: "hello", location: "/hello.skill.md"})
      :ok = Memory.delete(pid, "hello")

      {:ok, [kit]} = Memory.load_kits(provider: pid)
      assert kit.skills == []
    end
  end

  describe "load_kits/1 with empty provider" do
    test "returns kit with no skills", %{provider: pid} do
      {:ok, [kit]} = Memory.load_kits(provider: pid)

      assert kit.name == "memory"
      assert kit.skills == []
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
  In-memory skill provider for testing.

  Implements `SkillKit.Kit.Provider` backed by an `Agent`. Push skills
  into it with `put/2` — no filesystem, no cleanup.

      {:ok, provider} = SkillKit.Kit.Memory.start_link([])
      SkillKit.Kit.Memory.put(provider, %Skill{name: "hello", body: "...", location: "/hello.skill.md"})
      {:ok, [kit]} = SkillKit.Kit.Memory.load_kits(provider: provider)
  """

  @behaviour SkillKit.Kit.Provider

  alias SkillKit.Kit
  alias SkillKit.Skill

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @spec put(pid() | atom(), Skill.t()) :: :ok
  def put(provider, %Skill{} = skill) do
    Agent.update(provider, &Map.put(&1, skill.name, skill))
  end

  @spec delete(pid() | atom(), String.t()) :: :ok
  def delete(provider, name) do
    Agent.update(provider, &Map.delete(&1, name))
  end

  @impl SkillKit.Kit.Provider
  def load_kits(config) do
    provider = Keyword.fetch!(config, :provider)
    skills = Agent.get(provider, &Map.values/1)

    kit = %Kit{
      name: "memory",
      skills: skills,
      subagents: [],
      agent: nil,
      metadata: %{}
    }

    {:ok, [kit]}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/kit/memory_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Run full test suite**

Run: `mix test`
Expected: All existing tests still pass

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/kit/memory.ex test/skill_kit/kit/memory_test.exs
git commit -m "feat(kit): add in-memory skill provider for testing"
```

---

## Task 1: Skill Index — Track Skills, Hashes, and TTL

**Files:**
- Create: `lib/skill_kit/web/skill_index.ex`
- Create: `test/skill_kit/web/skill_index_test.exs`

The index loads skills from any provider, computes content hashes, and tracks TTL. It answers: "which skills need codegen right now?"

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SkillKit.Web.SkillIndexTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.Memory
  alias SkillKit.Skill
  alias SkillKit.Web.SkillIndex

  setup do
    {:ok, provider} = Memory.start_link([])

    :ok = Memory.put(provider, %Skill{
      name: "hello",
      description: "Hello page",
      body: "Render a page that says hello.",
      location: "/app/hello.skill.md",
      metadata: %{"cache" => %{"ttl" => 60}}
    })

    %{provider: provider}
  end

  describe "load/1" do
    test "loads skills and computes hashes", %{provider: provider} do
      index = SkillIndex.load(provider: provider)
      entries = SkillIndex.entries(index)

      assert length(entries) == 1
      [entry] = entries
      assert entry.route == "/app/hello"
      assert entry.skill.description == "Hello page"
      assert is_binary(entry.hash)
    end
  end

  describe "stale/1" do
    test "new entries are always stale", %{provider: provider} do
      index = SkillIndex.load(provider: provider)

      assert length(SkillIndex.stale(index)) == 1
    end

    test "entries are not stale after marking fresh", %{provider: provider} do
      index = SkillIndex.load(provider: provider)
      [entry] = SkillIndex.stale(index)
      index = SkillIndex.mark_fresh(index, entry.route)

      assert SkillIndex.stale(index) == []
    end

    test "entries become stale after TTL expires", %{provider: provider} do
      index = SkillIndex.load(provider: provider)
      [entry] = SkillIndex.stale(index)

      past = DateTime.add(DateTime.utc_now(), -120, :second)
      index = SkillIndex.mark_fresh(index, entry.route, past)

      assert length(SkillIndex.stale(index)) == 1
    end
  end

  describe "reload/1" do
    test "detects content changes", %{provider: provider} do
      index = SkillIndex.load(provider: provider)
      [entry] = SkillIndex.entries(index)
      original_hash = entry.hash

      :ok = Memory.put(provider, %Skill{
        name: "hello",
        description: "Hello page",
        body: "Render a page that says hello with a banner.",
        location: "/app/hello.skill.md",
        metadata: %{"cache" => %{"ttl" => 60}}
      })

      index = SkillIndex.reload(index)
      [entry] = SkillIndex.entries(index)

      assert entry.hash != original_hash
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/web/skill_index_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Write implementation**

```elixir
defmodule SkillKit.Web.SkillIndex do
  @moduledoc """
  Tracks skills, their content hashes, and TTL for codegen scheduling.

  Loads skills from any `Kit.Provider`, maps locations to routes,
  and determines which skills need codegen (new, changed, or TTL expired).
  """

  defstruct [:provider_config, entries: %{}]

  defmodule Entry do
    @moduledoc false
    defstruct [:route, :skill, :hash, :ttl, :generated_at]
  end

  @type t :: %__MODULE__{
    provider_config: keyword(),
    entries: %{String.t() => Entry.t()}
  }

  @default_ttl 3600

  @spec load(keyword()) :: t()
  def load(provider_config) do
    skills = load_skills(provider_config)
    entries = build_entries(skills)

    %__MODULE__{provider_config: provider_config, entries: entries}
  end

  @spec reload(t()) :: t()
  def reload(%__MODULE__{} = index) do
    skills = load_skills(index.provider_config)
    new_entries = build_entries(skills)

    merged =
      Map.merge(new_entries, index.entries, fn _route, new, old ->
        if new.hash == old.hash do
          old
        else
          new
        end
      end)

    %{index | entries: merged}
  end

  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{entries: entries}) do
    Map.values(entries)
  end

  @spec stale(t()) :: [Entry.t()]
  def stale(%__MODULE__{entries: entries}) do
    now = DateTime.utc_now()

    entries
    |> Map.values()
    |> Enum.filter(&stale_entry?(&1, now))
  end

  @spec mark_fresh(t(), String.t(), DateTime.t()) :: t()
  def mark_fresh(%__MODULE__{} = index, route, timestamp \\ DateTime.utc_now()) do
    entries = Map.update!(index.entries, route, fn entry ->
      %{entry | generated_at: timestamp}
    end)

    %{index | entries: entries}
  end

  defp stale_entry?(%Entry{generated_at: nil}, _now), do: true

  defp stale_entry?(%Entry{generated_at: generated_at, ttl: ttl}, now) do
    elapsed = DateTime.diff(now, generated_at, :second)
    elapsed >= ttl
  end

  defp load_skills(provider_config) do
    provider_module = provider_module(provider_config)

    case provider_module.load_kits(provider_config) do
      {:ok, kits} -> Enum.flat_map(kits, & &1.skills)
      {:error, _} -> []
    end
  end

  defp provider_module(config) do
    Keyword.get(config, :module, SkillKit.Kit.Memory)
  end

  defp build_entries(skills) do
    Map.new(skills, fn skill ->
      route = location_to_route(skill.location)
      ttl = extract_ttl(skill)
      hash = content_hash(skill)

      entry = %Entry{
        route: route,
        skill: skill,
        hash: hash,
        ttl: ttl,
        generated_at: nil
      }

      {route, entry}
    end)
  end

  defp location_to_route(location) do
    String.replace_suffix(location, ".skill.md", "")
  end

  defp extract_ttl(skill) do
    case get_in(skill.metadata || %{}, ["cache", "ttl"]) do
      ttl when is_integer(ttl) -> ttl
      _ -> @default_ttl
    end
  end

  defp content_hash(skill) do
    :crypto.hash(:sha256, skill.body || "")
    |> Base.encode16(case: :lower)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/web/skill_index_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/web/skill_index.ex test/skill_kit/web/skill_index_test.exs
git commit -m "feat(web): add SkillIndex to track skills, hashes, and TTL"
```

---

## Task 2: Generator — Spawn Agent to Generate Phoenix Code

**Files:**
- Create: `lib/skill_kit/web/codegen/generator.ex`
- Create: `test/skill_kit/web/codegen/generator_test.exs`

The generator takes a skill and spawns a SkillKit agent that reads the skill body and produces a Phoenix module as a string.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SkillKit.Web.Codegen.GeneratorTest do
  use ExUnit.Case, async: true

  alias SkillKit.Web.Codegen.Generator

  describe "system_prompt/2" do
    test "includes the skill body and route" do
      prompt = Generator.system_prompt("/app/hello", "Render a page that says hello.")

      assert prompt =~ "/app/hello"
      assert prompt =~ "Render a page that says hello."
      assert prompt =~ "defmodule"
    end
  end

  describe "module_name/1" do
    test "converts route to module name" do
      assert Generator.module_name("/app/hello") == "SkillKitWeb.Generated.App.Hello"
      assert Generator.module_name("/_admin/dashboard") == "SkillKitWeb.Generated.Admin.Dashboard"
      assert Generator.module_name("/api/webhooks/stripe") == "SkillKitWeb.Generated.Api.Webhooks.Stripe"
    end
  end

  describe "extract_module_source/1" do
    test "extracts elixir code from LLM response" do
      response = """
      Here's the module:

      ```elixir
      defmodule SkillKitWeb.Generated.App.Hello do
        use Phoenix.Controller, formats: [:html]

        def show(conn, _params) do
          html(conn, "<h1>Hello World</h1>")
        end
      end
      ```

      This module renders a simple hello page.
      """

      {:ok, source} = Generator.extract_module_source(response)
      assert source =~ "defmodule SkillKitWeb.Generated.App.Hello"
      assert source =~ "def show"
    end

    test "returns error when no code block found" do
      assert :error = Generator.extract_module_source("No code here.")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/web/codegen/generator_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Write implementation**

```elixir
defmodule SkillKit.Web.Codegen.Generator do
  @moduledoc """
  Generates Phoenix modules from skill specs using a SkillKit agent.

  Given a skill body (the spec) and a route, spawns an agent that
  produces an Elixir module implementing the route.
  """

  @doc """
  Builds the system prompt for the codegen agent.
  """
  @spec system_prompt(String.t(), String.t()) :: String.t()
  def system_prompt(route, skill_body) do
    mod = module_name(route)

    """
    You are a Phoenix code generator. Given a skill spec, generate a single Elixir module
    that implements the described route.

    Rules:
    - The module MUST be named `#{mod}`
    - Use `Phoenix.Controller` for page/API routes
    - Use `Phoenix.LiveView` for interactive routes
    - Return ONLY the module code in a ```elixir code block
    - The module must compile standalone (include all necessary `use`/`import` statements)
    - Include a `show/2` action for controller-based routes
    - Keep it simple — implement exactly what the spec describes

    Route: #{route}

    Skill spec:
    #{skill_body}
    """
  end

  @doc """
  Converts a route path to a module name.
  """
  @spec module_name(String.t()) :: String.t()
  def module_name(route) do
    parts =
      route
      |> String.split("/", trim: true)
      |> Enum.map(&clean_segment/1)
      |> Enum.map(&Macro.camelize/1)

    "SkillKitWeb.Generated." <> Enum.join(parts, ".")
  end

  @doc """
  Generates a Phoenix module by spawning a SkillKit agent.

  Returns `{:ok, source_code}` or `{:error, reason}`.
  """
  @spec generate(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(route, skill_body, opts \\ []) do
    prompt = system_prompt(route, skill_body)
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, agent} <- start_codegen_agent(prompt, opts),
         {:ok, response} <- get_response(agent, route, timeout) do
      SkillKit.stop_agent(agent)
      extract_module_source(response)
    end
  end

  @doc """
  Extracts Elixir source code from an LLM response.

  Looks for ```elixir code blocks containing a `defmodule`.
  """
  @spec extract_module_source(String.t()) :: {:ok, String.t()} | :error
  def extract_module_source(response) do
    case Regex.run(~r/```elixir\n(.*?)```/s, response) do
      [_, source] when byte_size(source) > 0 -> {:ok, String.trim(source)}
      _ -> :error
    end
  end

  defp start_codegen_agent(prompt, opts) do
    definition = %SkillKit.Agent.Definition{
      name: "codegen",
      description: "Generates Phoenix code from skill specs",
      system_prompt: prompt,
      capabilities: [],
      max_agent_depth: 0,
      mailbox: %{max_messages: 1, flush_interval: 100}
    }

    skills = Keyword.get(opts, :skills, [])

    SkillKit.start_agent(definition,
      caller: self(),
      skills: skills,
      scope: nil
    )
  end

  defp get_response(agent, route, timeout) do
    SkillKit.send_message(agent, "Generate the module for route: #{route}")
    receive_response("", timeout)
  end

  defp receive_response(acc, timeout) do
    receive do
      %SkillKit.Event.Delta{text: text} ->
        receive_response(acc <> text, timeout)

      %SkillKit.Types.AssistantMessage{content: content} when is_binary(content) ->
        {:ok, content}

      %SkillKit.Types.AssistantMessage{} ->
        {:ok, acc}

      %SkillKit.Event.Error{reason: reason} ->
        {:error, reason}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp clean_segment(segment) do
    String.replace_leading(segment, "_", "")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/web/codegen/generator_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/web/codegen/generator.ex test/skill_kit/web/codegen/generator_test.exs
git commit -m "feat(web): add Generator to produce Phoenix modules from skills"
```

---

## Task 3: Compiler — Compile and Test Generated Code

**Files:**
- Create: `lib/skill_kit/web/codegen/compiler.ex`
- Create: `test/skill_kit/web/codegen/compiler_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SkillKit.Web.Codegen.CompilerTest do
  use ExUnit.Case, async: true

  alias SkillKit.Web.Codegen.Compiler

  describe "compile_string/1" do
    test "compiles valid Elixir source" do
      source = """
      defmodule SkillKitWeb.Generated.Test.Valid#{System.unique_integer([:positive])} do
        def hello, do: "world"
      end
      """

      assert {:ok, modules} = Compiler.compile_string(source)
      assert length(modules) == 1
    end

    test "returns error for invalid source" do
      assert {:error, _reason} = Compiler.compile_string("defmodule Bad do {{{ end")
    end
  end

  describe "write_and_verify/3" do
    setup do
      output_dir = Path.join(System.tmp_dir!(), "skill_kit_compiler_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(output_dir)
      on_exit(fn -> File.rm_rf!(output_dir) end)
      %{output_dir: output_dir}
    end

    test "writes source to file on successful compile", %{output_dir: dir} do
      mod_id = System.unique_integer([:positive])

      source = """
      defmodule SkillKitWeb.Generated.Test.Written#{mod_id} do
        def hello, do: "written"
      end
      """

      assert {:ok, path} = Compiler.write_and_verify(source, "/test/written", dir)
      assert File.exists?(path)
      assert File.read!(path) =~ "def hello"
    end

    test "writes to .failed on compile error", %{output_dir: dir} do
      assert {:error, failed_path} = Compiler.write_and_verify("defmodule Bad do {{{ end", "/test/bad", dir)
      assert String.ends_with?(failed_path, ".failed.ex")
      assert File.exists?(failed_path)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/web/codegen/compiler_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Write implementation**

```elixir
defmodule SkillKit.Web.Codegen.Compiler do
  @moduledoc """
  Compiles generated Elixir source code and validates it.

  Attempts in-memory compilation first. On success, writes the `.ex` file
  to the output directory. On failure, writes to `.failed/` with a
  `.failed.ex` extension.
  """

  require Logger

  @spec compile_string(String.t()) :: {:ok, [module()]} | {:error, term()}
  def compile_string(source) do
    try do
      modules = Code.compile_string(source)
      module_names = Enum.map(modules, &elem(&1, 0))
      {:ok, module_names}
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @spec write_and_verify(String.t(), String.t(), String.t()) ::
    {:ok, String.t()} | {:error, String.t()}
  def write_and_verify(source, route, output_dir) do
    case compile_string(source) do
      {:ok, _modules} -> write_success(source, route, output_dir)
      {:error, reason} -> write_failure(source, route, output_dir, reason)
    end
  end

  defp write_success(source, route, output_dir) do
    path = generated_path(route, output_dir)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    Logger.info("Codegen: compiled #{route} → #{path}")
    {:ok, path}
  end

  defp write_failure(source, route, output_dir, reason) do
    failed_dir = Path.join(output_dir, ".failed")
    path = generated_path(route, failed_dir) <> ".failed.ex"
    File.mkdir_p!(Path.dirname(path))

    header = "# Codegen failure: #{inspect(reason)}\n# Route: #{route}\n\n"
    File.write!(path, header <> source)

    Logger.warning("Codegen: failed to compile #{route} — #{inspect(reason)}")
    {:error, path}
  end

  defp generated_path(route, base_dir) do
    relative =
      route
      |> String.split("/", trim: true)
      |> Enum.map(&String.replace_leading(&1, "_", ""))
      |> Enum.join("/")

    Path.join(base_dir, relative <> ".ex")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/web/codegen/compiler_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/web/codegen/compiler.ex test/skill_kit/web/codegen/compiler_test.exs
git commit -m "feat(web): add Compiler to validate and write generated code"
```

---

## Task 4: Loader — Hot-Reload Modules

**Files:**
- Create: `lib/skill_kit/web/codegen/loader.ex`
- Create: `test/skill_kit/web/codegen/loader_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SkillKit.Web.Codegen.LoaderTest do
  use ExUnit.Case, async: false

  alias SkillKit.Web.Codegen.Loader

  describe "load_source/1" do
    test "hot-reloads a module from source" do
      id = System.unique_integer([:positive])

      source_v1 = """
      defmodule SkillKitWeb.Generated.Test.HotReload#{id} do
        def version, do: 1
      end
      """

      assert :ok = Loader.load_source(source_v1)
      assert apply(:"Elixir.SkillKitWeb.Generated.Test.HotReload#{id}", :version, []) == 1

      source_v2 = """
      defmodule SkillKitWeb.Generated.Test.HotReload#{id} do
        def version, do: 2
      end
      """

      assert :ok = Loader.load_source(source_v2)
      assert apply(:"Elixir.SkillKitWeb.Generated.Test.HotReload#{id}", :version, []) == 2
    end

    test "returns error for invalid source" do
      assert {:error, _} = Loader.load_source("not valid {{{")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/web/codegen/loader_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Write implementation**

```elixir
defmodule SkillKit.Web.Codegen.Loader do
  @moduledoc """
  Hot-reloads generated modules into the running BEAM.

  Compiles source code and replaces any existing version of the module
  without requiring an application restart.
  """

  require Logger

  @spec load_source(String.t()) :: :ok | {:error, term()}
  def load_source(source) do
    try do
      modules = Code.compile_string(source)
      Enum.each(modules, &load_compiled/1)
      :ok
    rescue
      error -> {:error, Exception.message(error)}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp load_compiled({module, binary}) do
    :code.purge(module)
    :code.load_binary(module, ~c"generated", binary)
    Logger.info("Codegen: hot-reloaded #{inspect(module)}")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/web/codegen/loader_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/web/codegen/loader.ex test/skill_kit/web/codegen/loader_test.exs
git commit -m "feat(web): add Loader for hot-reloading generated modules"
```

---

## Task 5: Codegen GenServer — The Continuous Loop

**Files:**
- Create: `lib/skill_kit/web/codegen.ex`
- Create: `test/skill_kit/web/codegen_test.exs`

The GenServer ties everything together. It holds the SkillIndex, runs a timer for TTL checks, and exposes `signal/2` for outside triggers (including the exception triage handler).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule SkillKit.Web.CodegenTest do
  use ExUnit.Case, async: false

  alias SkillKit.Kit.Memory
  alias SkillKit.Skill
  alias SkillKit.Web.Codegen

  setup do
    {:ok, provider} = Memory.start_link([])

    :ok = Memory.put(provider, %Skill{
      name: "hello",
      description: "Hello page",
      body: "A simple page that returns the text \"Hello from codegen\" in an h1 tag.",
      location: "/app/hello.skill.md",
      metadata: %{"cache" => %{"ttl" => 3600}}
    })

    output_dir = Path.join(System.tmp_dir!(), "skill_kit_codegen_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(output_dir)
    on_exit(fn -> File.rm_rf!(output_dir) end)

    %{provider: provider, output_dir: output_dir}
  end

  describe "start_link/1" do
    test "starts the codegen server", %{provider: provider, output_dir: dir} do
      {:ok, pid} = Codegen.start_link(
        provider: provider,
        output_dir: dir,
        auto_start: false
      )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "status/1" do
    test "returns the current skill index", %{provider: provider, output_dir: dir} do
      {:ok, pid} = Codegen.start_link(
        provider: provider,
        output_dir: dir,
        auto_start: false
      )

      status = Codegen.status(pid)
      assert length(status.entries) == 1
      assert hd(status.entries).route == "/app/hello"

      GenServer.stop(pid)
    end
  end

  describe "signal/2" do
    test "accepts a signal without crashing", %{provider: provider, output_dir: dir} do
      {:ok, pid} = Codegen.start_link(
        provider: provider,
        output_dir: dir,
        auto_start: false
      )

      assert :ok = Codegen.signal(pid, "/app/hello")

      GenServer.stop(pid)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/web/codegen_test.exs`
Expected: FAIL — module not found

- [ ] **Step 3: Write implementation**

```elixir
defmodule SkillKit.Web.Codegen do
  @moduledoc """
  Continuous codegen server.

  Tracks skills via `SkillIndex`, periodically checks for stale entries
  (TTL expired or content changed), and triggers codegen cycles:
  skill → agent → generate → compile → test → hot-reload.

  ## Options

  - `:provider` — pid or name of a `Kit.Provider` (e.g., `Kit.Memory` pid)
  - `:output_dir` — path to write generated `.ex` files (required)
  - `:check_interval` — milliseconds between TTL checks (default: 30_000)
  - `:auto_start` — whether to start the check loop immediately (default: true)
  - `:agent_opts` — keyword opts passed to the codegen agent (default: [])
  """

  use GenServer

  require Logger

  alias SkillKit.Web.SkillIndex
  alias SkillKit.Web.Codegen.Generator
  alias SkillKit.Web.Codegen.Compiler
  alias SkillKit.Web.Codegen.Loader

  defstruct [:index, :output_dir, :check_interval, :agent_opts, :provider_config, :timer_ref]

  @default_check_interval 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc "Returns current status: entries and their staleness."
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc "Signals the server to re-evaluate a specific route."
  def signal(server, route) do
    GenServer.cast(server, {:signal, route})
  end

  @doc "Signals the server with error context from a generated module."
  def signal_error(server, route, error_context) do
    GenServer.cast(server, {:signal_error, route, error_context})
  end

  @doc "Triggers a full check cycle."
  def check(server) do
    GenServer.cast(server, :check)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    provider = Keyword.fetch!(opts, :provider)
    output_dir = Keyword.fetch!(opts, :output_dir)
    check_interval = Keyword.get(opts, :check_interval, @default_check_interval)
    auto_start = Keyword.get(opts, :auto_start, true)
    agent_opts = Keyword.get(opts, :agent_opts, [])

    provider_config = [provider: provider]
    index = SkillIndex.load(provider_config)
    File.mkdir_p!(output_dir)

    state = %__MODULE__{
      index: index,
      output_dir: output_dir,
      check_interval: check_interval,
      agent_opts: agent_opts,
      provider_config: provider_config,
      timer_ref: nil
    }

    state = if auto_start, do: schedule_check(state), else: state

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    entries = SkillIndex.entries(state.index)

    reply = %{
      entries: entries,
      output_dir: state.output_dir
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_cast({:signal, route}, state) do
    state = run_codegen_for_route(state, route)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:signal_error, route, error_context}, state) do
    state = run_codegen_for_route(state, route, error_context)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:check, state) do
    state = run_check_cycle(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_timer, state) do
    state = run_check_cycle(state)
    state = schedule_check(state)
    {:noreply, state}
  end

  # --- Internal ---

  defp schedule_check(state) do
    ref = Process.send_after(self(), :check_timer, state.check_interval)
    %{state | timer_ref: ref}
  end

  defp run_check_cycle(state) do
    index = SkillIndex.reload(state.index)
    stale = SkillIndex.stale(index)
    state = %{state | index: index}

    Enum.reduce(stale, state, fn entry, acc ->
      run_codegen_for_entry(acc, entry)
    end)
  end

  defp run_codegen_for_route(state, route, error_context \\ nil) do
    case Map.get(state.index.entries, route) do
      nil ->
        Logger.warning("Codegen: no skill found for route #{route}")
        state

      entry ->
        run_codegen_for_entry(state, entry, error_context)
    end
  end

  defp run_codegen_for_entry(state, entry, error_context \\ nil) do
    Logger.info("Codegen: generating #{entry.route}")
    body = build_body(entry.skill.body, error_context)

    case Generator.generate(entry.route, body, state.agent_opts) do
      {:ok, source} -> compile_and_load(state, entry, source)
      {:error, reason} -> handle_generation_error(state, entry, reason)
    end
  end

  defp build_body(skill_body, nil), do: skill_body

  defp build_body(skill_body, error_context) do
    skill_body <> "\n\n## Error Context\n\nThe previous generated code crashed:\n\n#{error_context}"
  end

  defp compile_and_load(state, entry, source) do
    case Compiler.write_and_verify(source, entry.route, state.output_dir) do
      {:ok, _path} -> load_and_mark_fresh(state, entry, source)
      {:error, _failed_path} -> state
    end
  end

  defp load_and_mark_fresh(state, entry, source) do
    case Loader.load_source(source) do
      :ok ->
        index = SkillIndex.mark_fresh(state.index, entry.route)
        %{state | index: index}

      {:error, reason} ->
        Logger.warning("Codegen: hot-reload failed for #{entry.route} — #{inspect(reason)}")
        state
    end
  end

  defp handle_generation_error(state, entry, reason) do
    Logger.warning("Codegen: generation failed for #{entry.route} — #{inspect(reason)}")
    state
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/web/codegen_test.exs`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/web/codegen.ex test/skill_kit/web/codegen_test.exs
git commit -m "feat(web): add Codegen GenServer for continuous code generation"
```

---

## Task 6: Example App

**Files:**
- Create: `examples/skill_kit_web/mix.exs`
- Create: `examples/skill_kit_web/config/config.exs`
- Create: `examples/skill_kit_web/config/dev.exs`
- Create: `examples/skill_kit_web/lib/skill_kit_web/application.ex`
- Create: `examples/skill_kit_web/lib/skill_kit_web/endpoint.ex`
- Create: `examples/skill_kit_web/lib/skill_kit_web/router.ex`
- Create: `examples/skill_kit_web/.skills/_admin/dashboard.skill.md`
- Create: `examples/skill_kit_web/.skills/app/hello.skill.md`

Minimal Phoenix app that starts the Codegen server and routes to generated modules. See the previous version of this task in git history for the full file contents — the structure is identical but now uses `Kit.Local` for the production filesystem provider (the memory provider is for tests only).

- [ ] **Step 1: Create all files**

`mix.exs`: Phoenix app depending on `skill_kit` via path.
`application.ex`: Starts Codegen server with `skills_dir: ".skills"`, `output_dir: "lib/generated"`.
`router.ex`: Routes point to `SkillKitWeb.Generated.*` modules. Catch-all returns 404.
`.skills/`: Two seed skills describing what the admin dashboard and hello page should do.

- [ ] **Step 2: Verify it works**

Run: `cd examples/skill_kit_web && mix deps.get && mix run --no-halt`

Watch logs for codegen cycles. Verify generated modules serve at `localhost:4000`.

- [ ] **Step 3: Commit**

```bash
git add examples/skill_kit_web/
git commit -m "feat(examples): add skill_kit_web with continuous codegen"
```

---

## Summary

7 tasks (0-6). The deliverables:

1. **`SkillKit.Kit.Memory`** — in-memory skill provider for tests. No disk, no cleanup.
2. **`SkillKit.Web.SkillIndex`** — tracks skills, hashes, TTL
3. **`SkillKit.Web.Codegen.Generator`** — spawns SkillKit agent to produce Phoenix modules
4. **`SkillKit.Web.Codegen.Compiler`** — compiles in memory, writes to disk, handles failures
5. **`SkillKit.Web.Codegen.Loader`** — hot-reloads via `Code.purge/load_binary`
6. **`SkillKit.Web.Codegen`** — GenServer: continuous loop with TTL + signals + error triage
7. **`examples/skill_kit_web`** — minimal Phoenix app that starts the Codegen server

**What's deferred:**
- `Codegen.TriageHandler` (Erlang logger handler for self-healing)
- Test runner gate (compile gate is in, test runner is Phase 2)
- Chat interface
- ExDoc content extraction
- Skill memory (`.memory.md`)
- Generated router auto-update
