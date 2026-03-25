# URI Model Strings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate provider configuration into URI model strings (`anthropic://model?opts`), make the LLM module own all provider resolution, and simplify the Server/Agent/Definition stack.

**Architecture:** `SkillKit.LLM.stream/2` parses the model URI, resolves the provider from a configurable registry, merges provider config + URI opts into one keyword list, and calls `provider.stream(messages, opts)`. The Server just passes `model:` and `system:`. Tests use a mock default provider via `config/test.exs`.

**Tech Stack:** Elixir/OTP, URI parsing, Application config, Mox

**Spec:** `docs/superpowers/specs/2026-03-23-uri-model-strings-design.md`

---

### Task 1: Add config files

**Files:**
- Create: `config/config.exs`
- Create: `config/test.exs`
- Create: `config/dev.exs`
- Create: `config/prod.exs`

- [ ] **Step 1: Create config files**

```elixir
# config/config.exs
import Config

config :skill_kit, SkillKit.LLM,
  providers: [
    anthropic: SkillKit.LLM.Anthropic
  ],
  default_provider: :anthropic

import_config "#{config_env()}.exs"
```

```elixir
# config/test.exs
import Config

config :skill_kit, SkillKit.LLM,
  providers: [
    anthropic: SkillKit.LLM.Anthropic,
    mock: SkillKit.LLM.Mock
  ],
  default_provider: :mock
```

```elixir
# config/dev.exs
import Config
```

```elixir
# config/prod.exs
import Config
```

- [ ] **Step 2: Compile and test**

Run: `mix compile && mix test`
Expected: All tests pass. Config loaded but old dispatch still in use.

- [ ] **Step 3: Commit**

```bash
git add config/
git commit -m "feat: add config files with provider registry"
```

---

### Task 2: Rewrite SkillKit.LLM with URI parsing

**Files:**
- Modify: `lib/skill_kit/llm/llm.ex`
- Modify: `test/skill_kit/llm_test.exs`

The behaviour callback changes from `stream/3` to `stream/2` — providers receive `(messages, opts)` where opts contains everything (config + request params merged).

- [ ] **Step 1: Write tests**

Add to `test/skill_kit/llm_test.exs`:

```elixir
describe "URI model resolution" do
  test "full URI resolves provider and model" do
    assert {:ok, SkillKit.LLM.Anthropic, opts} =
             SkillKit.LLM.get_provider_and_opts("anthropic://claude-sonnet-4-20250514")

    assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"
  end

  test "full URI with query params" do
    assert {:ok, SkillKit.LLM.Anthropic, opts} =
             SkillKit.LLM.get_provider_and_opts(
               "anthropic://claude-sonnet-4-20250514?max_tokens=4096&temperature=0.7"
             )

    assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"
    assert Keyword.get(opts, :max_tokens) == 4096
    assert Keyword.get(opts, :temperature) == 0.7
  end

  test "bare string uses default provider" do
    assert {:ok, SkillKit.LLM.Mock, opts} =
             SkillKit.LLM.get_provider_and_opts("claude-sonnet-4-20250514")

    assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"
  end

  test "bare string with query params uses default provider" do
    assert {:ok, SkillKit.LLM.Mock, opts} =
             SkillKit.LLM.get_provider_and_opts("claude-sonnet-4-20250514?max_tokens=2000")

    assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"
    assert Keyword.get(opts, :max_tokens) == 2000
  end

  test "nil model uses default provider" do
    assert {:ok, SkillKit.LLM.Mock, opts} = SkillKit.LLM.get_provider_and_opts(nil)
    assert opts == []
  end

  test "unknown scheme returns error with scheme name" do
    assert {:error, {:unknown_provider, "unknown"}} =
             SkillKit.LLM.get_provider_and_opts("unknown://model")
  end

  test "get_provider resolves by atom" do
    assert {:ok, SkillKit.LLM.Mock} = SkillKit.LLM.get_provider(:mock)
  end

  test "get_provider resolves by string" do
    assert {:ok, SkillKit.LLM.Mock} = SkillKit.LLM.get_provider("mock")
  end
end
```

- [ ] **Step 2: Implement the new LLM module**

Rewrite `lib/skill_kit/llm/llm.ex`:

```elixir
defmodule SkillKit.LLM do
  @moduledoc """
  Behaviour for LLM provider adapters and dispatch entry point.

  Resolves providers from model URI strings:

  - `"anthropic://claude-sonnet-4-20250514?max_tokens=8096"` — full URI
  - `"claude-sonnet-4-20250514"` — bare string, uses default provider
  - `"claude-sonnet-4-20250514?max_tokens=4096"` — bare with params

  ## Configuration

      config :skill_kit, SkillKit.LLM,
        providers: [anthropic: SkillKit.LLM.Anthropic],
        default_provider: :anthropic

      config :skill_kit, SkillKit.LLM.Anthropic,
        api_key: System.get_env("ANTHROPIC_API_KEY")
  """

  @type message :: SkillKit.LLM.Message.t()

  @callback stream(messages :: [message()], opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @doc "Streams a response from the resolved LLM provider."
  @spec stream([message()], keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream(messages, opts \\ []) do
    {model_string, opts} = Keyword.pop(opts, :model)

    case get_provider_and_opts(model_string) do
      {:ok, provider, provider_opts} ->
        merged = Keyword.merge(provider_opts, opts)
        provider.stream(messages, merged)

      {:error, _} = err ->
        err
    end
  end

  @doc "Resolves a model URI to `{:ok, provider, opts}` or `{:error, reason}`."
  @spec get_provider_and_opts(String.t() | nil) :: {:ok, module(), keyword()} | {:error, term()}
  def get_provider_and_opts(nil) do
    provider = default_provider()
    config = Application.get_env(:skill_kit, provider, [])
    {:ok, provider, config}
  end

  def get_provider_and_opts(model) when is_binary(model) do
    model
    |> URI.parse()
    |> resolve_uri()
  end

  @doc "Looks up a provider module by scheme name."
  @spec get_provider(atom() | String.t()) :: {:ok, module()} | {:error, term()}
  def get_provider(name) when is_binary(name) do
    name
    |> String.to_existing_atom()
    |> get_provider()
  rescue
    ArgumentError -> {:error, {:unknown_provider, name}}
  end

  def get_provider(name) when is_atom(name) do
    case Keyword.fetch(providers(), name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_provider, name}}
    end
  end

  # --- URI Resolution ---

  defp resolve_uri(%URI{scheme: nil} = uri) do
    default_key = Keyword.get(llm_config(), :default_provider, :anthropic)
    resolve_uri(%{uri | scheme: to_string(default_key)})
  end

  defp resolve_uri(%URI{host: nil, path: path} = uri) when is_binary(path) do
    resolve_uri(%{uri | host: path, path: nil})
  end

  defp resolve_uri(%URI{scheme: scheme, host: model_name, query: query}) do
    with {:ok, mod} <- get_provider(scheme) do
      config = Application.get_env(:skill_kit, mod, [])
      model_opts = parse_query_params(query) ++ [model: model_name]
      {:ok, mod, Keyword.merge(config, model_opts)}
    end
  end

  # --- Config ---

  defp llm_config, do: Application.get_env(:skill_kit, __MODULE__, [])

  defp providers do
    Keyword.get(llm_config(), :providers, [anthropic: __MODULE__.Anthropic])
  end

  defp default_provider do
    key = Keyword.get(llm_config(), :default_provider, :anthropic)
    Keyword.fetch!(providers(), key)
  end

  # --- Query Params ---

  @integer_params ~w(max_tokens)
  @float_params ~w(temperature top_p)

  defp parse_query_params(nil), do: []

  defp parse_query_params(query) do
    query
    |> URI.decode_query()
    |> Enum.map(&coerce_param/1)
  end

  defp coerce_param({key, value}) when key in @integer_params do
    case Integer.parse(value) do
      {int, ""} -> {String.to_atom(key), int}
      _ -> {String.to_atom(key), value}
    end
  end

  defp coerce_param({key, value}) when key in @float_params do
    case Float.parse(value) do
      {float, ""} -> {String.to_atom(key), float}
      _ -> {String.to_atom(key), value}
    end
  end

  defp coerce_param({key, value}), do: {String.to_atom(key), value}
end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/skill_kit/llm_test.exs -v`
Expected: New URI tests pass. Old tests that use `provider:` will fail — fixed in later tasks.

- [ ] **Step 4: Commit**

```bash
git add lib/skill_kit/llm/llm.ex test/skill_kit/llm_test.exs
git commit -m "feat: rewrite SkillKit.LLM with URI model string resolution"
```

---

### Task 3: Rewrite Anthropic adapter for stream/2

**Files:**
- Modify: `lib/skill_kit/llm/anthropic/anthropic.ex`
- Modify: `test/skill_kit/llm/anthropic_test.exs`

Callback changes from `stream(config, messages, opts)` to `stream(messages, opts)`. The adapter extracts its own config keys from opts.

- [ ] **Step 1: Rewrite the adapter**

```elixir
defmodule SkillKit.LLM.Anthropic do
  @moduledoc """
  Anthropic adapter for `SkillKit.LLM`.

  Sensitive config (api_key, endpoint) is resolved internally from
  app config and env vars — never from opts. Request params (model,
  max_tokens, temperature) are read from opts which may include
  URI query params set by skill authors.
  """

  @behaviour SkillKit.LLM

  alias SkillKit.LLM.Anthropic.Encoder

  @default_model "claude-sonnet-4-20250514"
  @default_max_tokens 8096
  @default_endpoint "https://api.anthropic.com"

  @impl true
  def stream(messages, opts) do
    # Sensitive — resolved internally, never from opts
    client = build_client()

    # Request params — trust opts (URI params, caller opts)
    encoded_messages = Encoder.encode_messages(messages)
    {tools, opts} = Keyword.pop(opts, :tools, [])
    encoded_tools = Encoder.encode_tools(tools)

    request_opts =
      opts
      |> Keyword.drop([:api_key, :endpoint])
      |> then(&if(encoded_tools != [], do: Keyword.put(&1, :tools, encoded_tools), else: &1))
      |> Keyword.put_new(:model, @default_model)
      |> Keyword.put_new(:max_tokens, @default_max_tokens)

    Anthropic.Client.stream(client, encoded_messages, request_opts)
  end

  defp build_client do
    config = Application.get_env(:skill_kit, __MODULE__, [])
    api_key = Keyword.get(config, :api_key) || System.get_env("ANTHROPIC_API_KEY")
    endpoint = Keyword.get(config, :endpoint, @default_endpoint)
    Anthropic.Client.new(api_key: api_key, endpoint: endpoint)
  end
end
```

- [ ] **Step 2: Update Mox mock definition**

In `test/test_helper.exs`, the mock is defined as `Mox.defmock(SkillKit.LLM.Mock, for: SkillKit.LLM)`. Since the callback changed from `stream/3` to `stream/2`, the mock auto-updates. But all test `expect` calls need updating from `fn _config, _messages, _opts ->` to `fn _messages, _opts ->`.

- [ ] **Step 3: Update Anthropic adapter tests**

In `test/skill_kit/llm/anthropic_test.exs`, update stream calls from `stream(config, messages, opts)` to `stream(messages, opts)` with config merged in.

- [ ] **Step 4: Run tests and commit**

Run: `mix test test/skill_kit/llm/ -v`

```bash
git add lib/skill_kit/llm/anthropic/anthropic.ex test/
git commit -m "feat: Anthropic adapter stream/2 with self-resolving credentials"
```

---

### Task 4: Simplify Server

**Files:**
- Modify: `lib/skill_kit/agent/server.ex`
- Modify: `test/skill_kit/agent/server_test.exs`

- [ ] **Step 1: Remove `:provider` from struct and init**

Remove from defstruct, @type, init, and state construction.

- [ ] **Step 2: Replace LLM call with stream/2 helper**

Replace the `llm_opts` block in `run_agent_loop`:

```elixir
case stream(state, tools) do
```

Add helper:

```elixir
defp stream(state, tools) do
  SkillKit.LLM.stream(state.messages,
    model: state.definition.model,
    system: state.definition.system_prompt,
    tools: tools
  )
end
```

- [ ] **Step 3: Remove provider from spawn_subagent**

Delete `if state.provider` conditional in `do_spawn_subagent`. Keep just `spawn_opts = [sources: state.sources]`.

- [ ] **Step 4: Update server tests**

Remove all `provider: {SkillKit.LLM.Mock, []}` from Server.start_link calls. Update all `expect(SkillKit.LLM.Mock, :stream, fn _config, _messages, _opts ->` to `fn _messages, _opts ->`.

- [ ] **Step 5: Run tests and commit**

```bash
git add lib/skill_kit/agent/server.ex test/skill_kit/agent/server_test.exs
git commit -m "refactor: remove provider from Server, extract stream/2 helper"
```

---

### Task 5: Remove provider from Agent, start_agent, start_subagent, and remaining tests

**Files:**
- Modify: `lib/skill_kit/agent/agent.ex`
- Modify: `lib/skill_kit.ex`
- Modify: `test/skill_kit_test.exs`
- Modify: `test/skill_kit/agent/agent_test.exs`
- Modify: `test/skill_kit/agent/loop_test.exs`
- Modify: `test/skill_kit/agent/core_test.exs`

- [ ] **Step 1: Remove provider from Agent.init**

Remove provider extraction, conditional put, and type.

- [ ] **Step 2: Remove provider from start_agent and start_subagent**

Remove from opts, agent_opts map, and @doc.

- [ ] **Step 3: Update all remaining tests**

Remove `provider:` from all start_agent/start_link calls. Update all Mock expect callbacks from 3-arity to 2-arity.

- [ ] **Step 4: Run full suite and precommit**

```bash
mix precommit
git add -A
git commit -m "refactor: remove provider from Agent, start_agent, all tests"
```

---

### Task 6: Remove max_tokens from Definition

**Files:**
- Modify: `lib/skill_kit/agent/definition.ex`
- Modify: `test/skill_kit/agent/definition_test.exs`

- [ ] **Step 1: Remove max_tokens**

Remove `@default_max_tokens`, field from struct/type, and `parse_int` call in build.

- [ ] **Step 2: Update tests**

Remove `max_tokens` assertions and struct fields from all tests.

- [ ] **Step 3: Precommit and commit**

```bash
mix precommit
git add -A
git commit -m "refactor: remove max_tokens from Definition"
```

---

### Task 7: Update examples and Mix tasks

**Files:**
- Modify: `examples/agents/*/AGENT.md`
- Modify: `lib/mix/tasks/skill_kit.demo.ex`
- Modify: `lib/mix/tasks/skill_kit.chat.ex`

- [ ] **Step 1: Update example agents with URI model strings**

```yaml
model: "anthropic://claude-sonnet-4-20250514"
```

Or leave `model:` off to use the configured default.

- [ ] **Step 2: Remove provider and api_key from Mix tasks**

Remove `provider: {...}`, `api_key = System.get_env(...)`, and the `unless api_key` check. The adapter resolves credentials from config/env.

- [ ] **Step 3: Test demo**

Run: `export ANTHROPIC_API_KEY=... && mix skill_kit.demo "What is 2 + 2?"`

- [ ] **Step 4: Precommit and commit**

```bash
mix precommit
git add -A
git commit -m "feat: update examples and Mix tasks for URI model strings"
```

---

### Task 8: Final cleanup

- [ ] **Step 1: Search for stale references**

Run: `grep -rn "default_provider_tuple\|provider:" lib/ test/ --include="*.ex" --include="*.exs"`
Expected: No hits except config files and comments.

- [ ] **Step 2: Run precommit**

Run: `mix precommit`

- [ ] **Step 3: Run docs**

Run: `mix docs`

- [ ] **Step 4: Commit if needed**

```bash
git add -A
git commit -m "chore: final cleanup for URI model strings"
```
