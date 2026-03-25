# Test Helpers & Synchronous send_message Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `send_message_sync/3`, response type structs, and `SkillKit.Test` helpers to eliminate non-deterministic `Process.sleep` from all tests.

**Architecture:** Response types (`SkillKit.Response.Text`, `ToolCall`, `Error`) are first-class library types with a `Respondable` protocol. `SkillKit.Test` provides SSE event builders (Layer 1) and Mox convenience helpers (Layer 2). `send_message_sync/3` does a direct `receive` in the caller process.

**Tech Stack:** Elixir 1.17, ExUnit, Mox, SkillKit.LLM.Anthropic.Decoder (for validating event builders)

**Spec:** `@docs/superpowers/specs/2026-03-23-test-helpers-design.md`

**Code style:** No alias shortcuts. No single-pipe chains. Prefer capture syntax (`&`) over `fn`. Extract multiline expressions to private helpers.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `lib/skill_kit/response/text.ex` | `%Response.Text{}` struct |
| `lib/skill_kit/response/tool_call.ex` | `%Response.ToolCall{}` struct |
| `lib/skill_kit/response/error.ex` | `%Response.Error{}` struct |
| `lib/skill_kit/response/respondable.ex` | `Respondable` protocol + implementations for all three types |
| `lib/skill_kit/test.ex` | `SkillKit.Test` — `__using__` macro, event builders, `expect_response/1`, `assert_response/2`, `expect_responses/1`, `expect_error/2`, `start_server/1` |
| `lib/skill_kit.ex` | Add `send_message_sync/3` |
| `test/skill_kit/response/respondable_test.exs` | Tests for Respondable protocol |
| `test/skill_kit/test_test.exs` | Tests for SkillKit.Test helpers |
| `test/skill_kit_test.exs` | Migrate to new helpers |
| `test/skill_kit/agent/server_test.exs` | Migrate to new helpers, remove all Process.sleep |

---

### Task 1: Response Type Structs

**Files:**
- Create: `lib/skill_kit/response/text.ex`
- Create: `lib/skill_kit/response/tool_call.ex`
- Create: `lib/skill_kit/response/error.ex`

- [ ] **Step 1: Create `SkillKit.Response.Text`**

```elixir
# lib/skill_kit/response/text.ex
defmodule SkillKit.Response.Text do
  @moduledoc """
  Describes an LLM text response.
  """

  @type t :: %__MODULE__{content: String.t()}

  @enforce_keys [:content]
  defstruct [:content]
end
```

- [ ] **Step 2: Create `SkillKit.Response.ToolCall`**

```elixir
# lib/skill_kit/response/tool_call.ex
defmodule SkillKit.Response.ToolCall do
  @moduledoc """
  Describes an LLM tool call response.
  """

  @type t :: %__MODULE__{name: String.t(), input: map()}

  @enforce_keys [:name, :input]
  defstruct [:name, :input]
end
```

- [ ] **Step 3: Create `SkillKit.Response.Error`**

```elixir
# lib/skill_kit/response/error.ex
defmodule SkillKit.Response.Error do
  @moduledoc """
  Describes an LLM error response.
  """

  @type t :: %__MODULE__{status: integer(), message: String.t()}

  @enforce_keys [:status, :message]
  defstruct [:status, :message]
end
```

- [ ] **Step 4: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS, no warnings

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/response/
git commit -m "feat: add Response.Text, Response.ToolCall, Response.Error structs"
```

---

### Task 2: SSE Event Builders (Layer 1)

**Files:**
- Create: `lib/skill_kit/test.ex`
- Create: `test/skill_kit/test_test.exs`

- [ ] **Step 1: Write failing test for `text_events/1`**

```elixir
# test/skill_kit/test_test.exs
defmodule SkillKit.TestTest do
  use ExUnit.Case, async: true

  alias SkillKit.LLM.Anthropic.Decoder
  alias SkillKit.LLM.Message

  describe "text_events/1" do
    test "produces events that decode to a text Assistant message" do
      events = SkillKit.Test.text_events("Hello world")
      result = Decoder.decode_events(events)

      assert %Message.Assistant{content: "Hello world", tool_calls: []} = result
    end

    test "returns a list of 6 SSE event maps" do
      events = SkillKit.Test.text_events("Hi")

      assert length(events) == 6
      assert %{"type" => "message_start"} = List.first(events)
      assert %{"type" => "message_stop"} = List.last(events)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/test_test.exs --trace`
Expected: FAIL — `SkillKit.Test.text_events/1 is undefined`

- [ ] **Step 3: Implement `text_events/1`**

```elixir
# lib/skill_kit/test.ex
defmodule SkillKit.Test do
  @moduledoc """
  Test helpers for SkillKit.

  Provides SSE event builders and Mox convenience helpers for testing
  agents and LLM interactions.

  ## Setup

      use SkillKit.Test

  This imports `SkillKit.Test` and sets up `Mox.verify_on_exit!/1`.
  """

  @doc """
  Builds a complete Anthropic SSE event sequence for a text response.

  Returns a list of 6 event maps that decode to
  `%Message.Assistant{content: text, tool_calls: []}`.
  """
  @spec text_events(String.t()) :: [map()]
  def text_events(text) do
    msg_id = "msg_test_#{:erlang.unique_integer([:positive])}"

    [
      %{
        "type" => "message_start",
        "message" => %{"id" => msg_id, "role" => "assistant", "content" => []}
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
      %{"type" => "message_stop"}
    ]
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/test_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Write failing test for `tool_call_events/2`**

Add to `test/skill_kit/test_test.exs`:

```elixir
describe "tool_call_events/2" do
  test "produces events that decode to a tool call Assistant message" do
    events = SkillKit.Test.tool_call_events("echo", %{"command" => "echo hi"})
    result = Decoder.decode_events(events)

    assert %Message.Assistant{content: nil, tool_calls: [tool_call]} = result
    assert tool_call.name == "echo"
    assert tool_call.input == %{"command" => "echo hi"}
  end

  test "returns a list of 6 SSE event maps" do
    events = SkillKit.Test.tool_call_events("bash", %{"cmd" => "ls"})

    assert length(events) == 6
    assert %{"type" => "message_start"} = List.first(events)
    assert %{"type" => "message_stop"} = List.last(events)
  end
end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `mix test test/skill_kit/test_test.exs --trace`
Expected: FAIL — `SkillKit.Test.tool_call_events/2 is undefined`

- [ ] **Step 7: Implement `tool_call_events/2`**

Add to `lib/skill_kit/test.ex`:

```elixir
@doc """
Builds a complete Anthropic SSE event sequence for a tool call response.

Returns a list of 6 event maps that decode to
`%Message.Assistant{content: nil, tool_calls: [%ToolCall{name: name, input: input}]}`.
"""
@spec tool_call_events(String.t(), map()) :: [map()]
def tool_call_events(name, input) do
  msg_id = "msg_test_#{:erlang.unique_integer([:positive])}"
  tool_call_id = "tc_test_#{:erlang.unique_integer([:positive])}"

  [
    %{
      "type" => "message_start",
      "message" => %{"id" => msg_id, "role" => "assistant", "content" => []}
    },
    %{
      "type" => "content_block_start",
      "index" => 0,
      "content_block" => %{
        "type" => "tool_use",
        "id" => tool_call_id,
        "name" => name,
        "input" => %{}
      }
    },
    %{
      "type" => "content_block_delta",
      "index" => 0,
      "delta" => %{"type" => "input_json_delta", "partial_json" => Jason.encode!(input)}
    },
    %{"type" => "content_block_stop", "index" => 0},
    %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
    %{"type" => "message_stop"}
  ]
end
```

- [ ] **Step 8: Run test to verify it passes**

Run: `mix test test/skill_kit/test_test.exs --trace`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add lib/skill_kit/test.ex test/skill_kit/test_test.exs
git commit -m "feat: add SkillKit.Test with text_events/1 and tool_call_events/2"
```

---

### Task 3: Respondable Protocol

**Files:**
- Create: `lib/skill_kit/response/respondable.ex`
- Create: `test/skill_kit/response/respondable_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
# test/skill_kit/response/respondable_test.exs
defmodule SkillKit.Response.RespondableTest do
  use ExUnit.Case, async: true

  alias SkillKit.LLM.Anthropic.Decoder
  alias SkillKit.LLM.Message
  alias SkillKit.Response.Error
  alias SkillKit.Response.Respondable
  alias SkillKit.Response.Text
  alias SkillKit.Response.ToolCall

  describe "to_stream/1" do
    test "Text returns stream that decodes to text message" do
      {:ok, stream} = Respondable.to_stream(%Text{content: "Hello"})
      events = Enum.to_list(stream)

      assert %Message.Assistant{content: "Hello", tool_calls: []} =
               Decoder.decode_events(events)
    end

    test "ToolCall returns stream that decodes to tool call message" do
      {:ok, stream} = Respondable.to_stream(%ToolCall{name: "bash", input: %{"cmd" => "ls"}})
      events = Enum.to_list(stream)
      result = Decoder.decode_events(events)

      assert %Message.Assistant{tool_calls: [tc]} = result
      assert tc.name == "bash"
      assert tc.input == %{"cmd" => "ls"}
    end

    test "Error returns error tuple" do
      assert {:error, {500, "boom"}} =
               Respondable.to_stream(%Error{status: 500, message: "boom"})
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/response/respondable_test.exs --trace`
Expected: FAIL — `Respondable` protocol not defined

- [ ] **Step 3: Implement protocol and all three implementations**

```elixir
# lib/skill_kit/response/respondable.ex
defprotocol SkillKit.Response.Respondable do
  @moduledoc """
  Converts a response type struct into what `SkillKit.LLM.stream/2` would return.
  """

  @spec to_stream(t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def to_stream(response)
end

defimpl SkillKit.Response.Respondable, for: SkillKit.Response.Text do
  def to_stream(%{content: content}) do
    events = SkillKit.Test.text_events(content)
    {:ok, Stream.map(events, & &1)}
  end
end

defimpl SkillKit.Response.Respondable, for: SkillKit.Response.ToolCall do
  def to_stream(%{name: name, input: input}) do
    events = SkillKit.Test.tool_call_events(name, input)
    {:ok, Stream.map(events, & &1)}
  end
end

defimpl SkillKit.Response.Respondable, for: SkillKit.Response.Error do
  def to_stream(%{status: status, message: message}) do
    {:error, {status, message}}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/response/respondable_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit/response/respondable.ex test/skill_kit/response/respondable_test.exs
git commit -m "feat: add Respondable protocol with Text, ToolCall, Error implementations"
```

---

### Task 4: Test Response Helpers (Layer 2)

**Files:**
- Modify: `lib/skill_kit/test.ex`
- Modify: `test/skill_kit/test_test.exs`

- [ ] **Step 1: Write failing test for `expect_response/1`**

Add to `test/skill_kit/test_test.exs`:

```elixir
alias SkillKit.Response.Text
alias SkillKit.Response.ToolCall
alias SkillKit.Response.Error

describe "expect_response/1" do
  setup :verify_on_exit!

  test "sets up Mox expectation for Text" do
    SkillKit.Test.expect_response(%Text{content: "Hello"})

    {:ok, stream} = SkillKit.LLM.Mock.stream([], [])
    events = Enum.to_list(stream)
    result = Decoder.decode_events(events)

    assert %Message.Assistant{content: "Hello"} = result
  end

  test "sets up Mox expectation for ToolCall" do
    SkillKit.Test.expect_response(%ToolCall{name: "bash", input: %{"cmd" => "ls"}})

    {:ok, stream} = SkillKit.LLM.Mock.stream([], [])
    events = Enum.to_list(stream)
    result = Decoder.decode_events(events)

    assert %Message.Assistant{tool_calls: [tc]} = result
    assert tc.name == "bash"
  end

  test "sets up Mox expectation for Error" do
    SkillKit.Test.expect_response(%Error{status: 429, message: "rate limited"})

    assert {:error, {429, "rate limited"}} = SkillKit.LLM.Mock.stream([], [])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit/test_test.exs:"expect_response" --trace`
Expected: FAIL — `SkillKit.Test.expect_response/1 is undefined`

- [ ] **Step 3: Implement `expect_response/1`**

Add to `lib/skill_kit/test.ex`:

```elixir
alias SkillKit.Response.Respondable

@doc """
Sets up a single Mox expectation that returns the given response.

## Examples

    expect_response(%Text{content: "Hello"})
    expect_response(%ToolCall{name: "bash", input: %{"cmd" => "ls"}})
    expect_response(%Error{status: 500, message: "boom"})
"""
@spec expect_response(struct()) :: :ok
def expect_response(response) do
  Mox.expect(SkillKit.LLM.Mock, :stream, 1, fn _messages, _opts ->
    Respondable.to_stream(response)
  end)

  :ok
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit/test_test.exs:"expect_response" --trace`
Expected: PASS

- [ ] **Step 5: Write failing test for `assert_response/2`**

Add to `test/skill_kit/test_test.exs`:

```elixir
describe "assert_response/2" do
  setup :verify_on_exit!

  test "runs assertion callback before returning response" do
    test_pid = self()

    SkillKit.Test.assert_response(%Text{content: "4"}, fn messages, opts ->
      send(test_pid, {:asserted, messages, opts})
    end)

    {:ok, _stream} = SkillKit.LLM.Mock.stream([%{role: "user"}], model: "test")

    assert_receive {:asserted, [%{role: "user"}], [model: "test"]}
  end

  test "returns correct response after assertion" do
    SkillKit.Test.assert_response(%Text{content: "Hello"}, fn _messages, _opts -> :ok end)

    {:ok, stream} = SkillKit.LLM.Mock.stream([], [])
    result = Decoder.decode_events(Enum.to_list(stream))

    assert %Message.Assistant{content: "Hello"} = result
  end
end
```

- [ ] **Step 6: Run test to verify it fails**

Run: `mix test test/skill_kit/test_test.exs:"assert_response" --trace`
Expected: FAIL — `SkillKit.Test.assert_response/2 is undefined`

- [ ] **Step 7: Implement `assert_response/2`**

Add to `lib/skill_kit/test.ex`:

```elixir
@doc """
Sets up a Mox expectation that runs the assertion callback, then returns the response.

The callback receives `(messages, opts)` — the arguments the LLM mock was called with.

## Examples

    assert_response(%Text{content: "4"}, fn _messages, opts ->
      assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"
    end)
"""
@spec assert_response(struct(), (list(), keyword() -> any())) :: :ok
def assert_response(response, assertion_fn) do
  Mox.expect(SkillKit.LLM.Mock, :stream, 1, fn messages, opts ->
    assertion_fn.(messages, opts)
    Respondable.to_stream(response)
  end)

  :ok
end
```

- [ ] **Step 8: Run test to verify it passes**

Run: `mix test test/skill_kit/test_test.exs:"assert_response" --trace`
Expected: PASS

- [ ] **Step 9: Write failing test for `expect_responses/1`**

Add to `test/skill_kit/test_test.exs`:

```elixir
describe "expect_responses/1" do
  setup :verify_on_exit!

  test "sets up sequential Mox expectations" do
    SkillKit.Test.expect_responses([
      %ToolCall{name: "echo", input: %{"cmd" => "hi"}},
      %Text{content: "Done!"}
    ])

    # First call returns tool call
    {:ok, stream1} = SkillKit.LLM.Mock.stream([], [])
    result1 = Decoder.decode_events(Enum.to_list(stream1))
    assert %Message.Assistant{tool_calls: [tc]} = result1
    assert tc.name == "echo"

    # Second call returns text
    {:ok, stream2} = SkillKit.LLM.Mock.stream([], [])
    result2 = Decoder.decode_events(Enum.to_list(stream2))
    assert %Message.Assistant{content: "Done!"} = result2
  end
end
```

- [ ] **Step 10: Run test to verify it fails**

Run: `mix test test/skill_kit/test_test.exs:"expect_responses" --trace`
Expected: FAIL — `SkillKit.Test.expect_responses/1 is undefined`

- [ ] **Step 11: Implement `expect_responses/1`**

Add to `lib/skill_kit/test.ex`:

```elixir
@doc """
Sets up multi-call Mox expectations from a list of response types.

Each element corresponds to one `LLM.stream` call in order.

## Examples

    expect_responses([
      %ToolCall{name: "echo", input: %{"cmd" => "hi"}},
      %Text{content: "Done!"}
    ])
"""
@spec expect_responses([struct()]) :: :ok
def expect_responses(responses) do
  count = length(responses)
  counter = :counters.new(1, [:atomics])
  responses_list = :lists.zip(:lists.seq(1, count), responses)
  responses_map = Map.new(responses_list)

  Mox.expect(SkillKit.LLM.Mock, :stream, count, fn _messages, _opts ->
    index = :counters.get(counter, 1) + 1
    :counters.put(counter, 1, index)
    Respondable.to_stream(Map.fetch!(responses_map, index))
  end)

  :ok
end
```

- [ ] **Step 12: Write failing test for `expect_error/2`**

Add to `test/skill_kit/test_test.exs`:

```elixir
describe "expect_error/2" do
  setup :verify_on_exit!

  test "sets up Mox expectation returning error tuple" do
    SkillKit.Test.expect_error(500, "internal error")

    assert {:error, {500, "internal error"}} = SkillKit.LLM.Mock.stream([], [])
  end
end
```

- [ ] **Step 13: Run test to verify it fails**

Run: `mix test test/skill_kit/test_test.exs:"expect_error" --trace`
Expected: FAIL — `SkillKit.Test.expect_error/2 is undefined`

- [ ] **Step 14: Implement `expect_error/2`**

Add to `lib/skill_kit/test.ex`:

```elixir
alias SkillKit.Response.Error

@doc """
Sets up a Mox expectation returning an LLM error.

## Examples

    expect_error(500, "internal error")
"""
@spec expect_error(integer(), String.t()) :: :ok
def expect_error(status, message) do
  expect_response(%Error{status: status, message: message})
end
```

- [ ] **Step 15: Run all tests to verify they pass**

Run: `mix test test/skill_kit/test_test.exs --trace`
Expected: PASS (all tests)

- [ ] **Step 16: Commit**

```bash
git add lib/skill_kit/test.ex test/skill_kit/test_test.exs
git commit -m "feat: add expect_response, assert_response, expect_responses, expect_error helpers"
```

---

### Task 5: `use SkillKit.Test` Macro and `start_server/1`

**Files:**
- Modify: `lib/skill_kit/test.ex`
- Modify: `test/skill_kit/test_test.exs`

- [ ] **Step 1: Add `__using__` macro**

Add to `lib/skill_kit/test.ex`:

```elixir
defmacro __using__(_opts) do
  quote do
    import SkillKit.Test
    setup :verify_on_exit!
  end
end
```

- [ ] **Step 2: Write failing test for `start_server/1`**

Add to `test/skill_kit/test_test.exs`:

```elixir
describe "start_server/1" do
  test "starts a registered Server with unique registry" do
    SkillKit.Test.expect_response(%SkillKit.Response.Text{content: "Hi"})

    {:ok, pid, context} = SkillKit.Test.start_server(caller: self())

    assert Process.alive?(pid)
    assert is_atom(context.registry)
    assert is_binary(context.agent_name)

    send(pid, {:mailbox_flush, [%Message.User{content: "hello"}]})

    assert_receive {:skill_kit, _, {:response, "Hi"}}, 1000
  end

  test "accepts custom options" do
    {:ok, pid, context} = SkillKit.Test.start_server(
      agent_name: "custom-agent",
      scope: ["test:read"]
    )

    assert Process.alive?(pid)
    assert context.agent_name == "custom-agent"

    state = :sys.get_state(pid)
    assert state.scope == ["test:read"]
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/skill_kit/test_test.exs:"start_server" --trace`
Expected: FAIL — `SkillKit.Test.start_server/1 is undefined`

- [ ] **Step 4: Implement `start_server/1`**

Add to `lib/skill_kit/test.ex`:

```elixir
alias SkillKit.Agent.Definition
alias SkillKit.Agent.Server

@doc """
Starts a bare Server process for unit testing.

Returns `{:ok, server_pid, context}` where context contains `:registry`,
`:agent_name`, and `:definition`.

## Options

  * `:caller` — pid to receive events (default: `self()`)
  * `:definition` — override default definition
  * `:agent_name` — override generated name
  * `:kits` — kits to pass to server
  * `:scope` — authorization scopes

## Examples

    {:ok, pid, ctx} = SkillKit.Test.start_server(caller: self())
"""
@spec start_server(keyword()) :: {:ok, pid(), map()}
def start_server(opts \\ []) do
  agent_name = Keyword.get(opts, :agent_name, "test-agent-#{:erlang.unique_integer([:positive])}")
  caller = Keyword.get(opts, :caller, self())
  scope = Keyword.get(opts, :scope)
  kits = Keyword.get(opts, :kits, [])

  definition =
    Keyword.get_lazy(opts, :definition, fn ->
      %Definition{
        name: agent_name,
        description: "Test agent",
        system_prompt: "You are a test agent.",
        path: "/tmp/test",
        workspace: "/tmp/test"
      }
    end)

  registry_name = :"test_registry_#{:erlang.unique_integer([:positive])}"
  ExUnit.Callbacks.start_supervised!({Registry, keys: :unique, name: registry_name})

  server_opts = [caller: caller, kits: kits]

  {:ok, pid} = Server.start_link({agent_name, definition, 0, nil, scope, registry_name, server_opts})

  Mox.allow(SkillKit.LLM.Mock, self(), pid)

  context = %{registry: registry_name, agent_name: agent_name, definition: definition}
  {:ok, pid, context}
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/skill_kit/test_test.exs:"start_server" --trace`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/test.ex test/skill_kit/test_test.exs
git commit -m "feat: add use SkillKit.Test macro and start_server/1 scaffolding helper"
```

---

### Task 6: `send_message_sync/3`

**Files:**
- Modify: `lib/skill_kit.ex`
- Modify: `test/skill_kit_test.exs`

- [ ] **Step 1: Write failing test**

Add a new describe block to `test/skill_kit_test.exs`:

```elixir
describe "send_message_sync/3" do
  test "blocks and returns {:ok, text} for text response" do
    definition = %SkillKit.Agent.Definition{
      name: "sync-test-agent",
      description: "Test",
      system_prompt: "Test",
      path: "/tmp/test",
      workspace: "/tmp/test",
      model: "test-model"
    }

    SkillKit.Test.expect_response(%SkillKit.Response.Text{content: "Hello world"})

    {:ok, agent} = SkillKit.start_agent(definition, caller: self())

    assert {:ok, "Hello world"} = SkillKit.send_message_sync(agent, "Hi")

    SkillKit.stop_agent(agent)
  end

  test "returns {:error, reason} for LLM errors" do
    definition = %SkillKit.Agent.Definition{
      name: "sync-error-agent",
      description: "Test",
      system_prompt: "Test",
      path: "/tmp/test",
      workspace: "/tmp/test"
    }

    SkillKit.Test.expect_error(500, "internal error")

    {:ok, agent} = SkillKit.start_agent(definition, caller: self())

    assert {:error, {500, "internal error"}} = SkillKit.send_message_sync(agent, "Hi")

    SkillKit.stop_agent(agent)
  end

  test "deltas arrive at caller before send_message_sync returns" do
    definition = %SkillKit.Agent.Definition{
      name: "sync-delta-agent",
      description: "Test",
      system_prompt: "Test",
      path: "/tmp/test",
      workspace: "/tmp/test",
      model: "test-model"
    }

    SkillKit.Test.expect_response(%SkillKit.Response.Text{content: "Hello world"})

    {:ok, agent} = SkillKit.start_agent(definition, caller: self())

    {:ok, "Hello world"} = SkillKit.send_message_sync(agent, "Hi")

    # Deltas should be in the mailbox — they arrived before :response
    assert_receive {:skill_kit, "sync-delta-agent", {:delta, "Hello world"}}

    SkillKit.stop_agent(agent)
  end

  test "returns {:error, :timeout} when timeout expires" do
    definition = %SkillKit.Agent.Definition{
      name: "sync-timeout-agent",
      description: "Test",
      system_prompt: "Test",
      path: "/tmp/test",
      workspace: "/tmp/test"
    }

    # Mock that never returns — simulate a halted server
    Mox.expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
      Process.sleep(:infinity)
    end)

    {:ok, agent} = SkillKit.start_agent(definition, caller: self())

    assert {:error, :timeout} = SkillKit.send_message_sync(agent, "Hi", 100)

    SkillKit.stop_agent(agent)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/skill_kit_test.exs:"send_message_sync" --trace`
Expected: FAIL — `SkillKit.send_message_sync/3 is undefined`

- [ ] **Step 3: Implement `send_message_sync/3`**

Add to `lib/skill_kit.ex` after `send_message/2`:

```elixir
@doc """
Sends a message and blocks until the agent responds.

Returns `{:ok, text}` on success, `{:error, reason}` on LLM error,
or `{:error, :timeout}` if the turn doesn't complete within `timeout` ms.

Must be called from the process registered as `:caller` in `start_agent/2`.
Intermediate events (`:delta`, `:tool_call`, `:tool_result`) remain in
the caller's mailbox and are not consumed.

## Examples

    {:ok, "Hello!"} = SkillKit.send_message_sync(agent, "Hi")
    {:error, :timeout} = SkillKit.send_message_sync(agent, "Hi", 100)
"""
@spec send_message_sync(agent(), String.t(), timeout()) ::
  {:ok, String.t() | nil} | {:error, term()}
def send_message_sync(%AgentRef{} = agent, content, timeout \\ 5000) do
  case send_message(agent, content) do
    :ok -> await_response(agent.name, timeout)
    {:error, reason} -> {:error, reason}
  end
end

defp await_response(agent_name, timeout) do
  receive do
    {:skill_kit, ^agent_name, {:response, text}} -> {:ok, text}
    {:skill_kit, ^agent_name, {:error, reason}} -> {:error, reason}
  after
    timeout -> {:error, :timeout}
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/skill_kit_test.exs:"send_message_sync" --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/skill_kit.ex test/skill_kit_test.exs
git commit -m "feat: add send_message_sync/3 for synchronous agent interaction"
```

---

### Task 7: Migrate `skill_kit_test.exs` to New Helpers

**Files:**
- Modify: `test/skill_kit_test.exs`

- [ ] **Step 1: Replace manual event construction and Process.sleep with helpers**

Rewrite `test/skill_kit_test.exs` to use `SkillKit.Test`, `send_message_sync`, and response types:

1. **"full lifecycle with streaming deltas" test**: Replace manual SSE event construction with `expect_response(%Text{content: "Hello world"})`. Use `send_message_sync` then `assert_receive` for deltas left in mailbox.

2. **"send_message returns {:error, :not_found} for stopped agent" test**: The `Process.sleep(50)` after `stop_agent` waits for OTP shutdown — keep it. This is not an LLM response wait.

3. **"stop_agent cleans up registry" test**: Same — `Process.sleep(50)` is for OTP process shutdown. Keep it.

4. **"conversation_store persists and restores messages" test**: Replace SSE events with `expect_response`. Use `send_message_sync` instead of `send_message + assert_receive`. Keep `Process.sleep(100)` after sync return (waits for async `save_conversation`). Keep `Process.sleep(50)` after `stop_agent` (OTP shutdown).

Run: `mix test test/skill_kit_test.exs --trace`
Expected: PASS (Process.sleep only remains for OTP shutdown waits and async save, never for LLM response waits)

- [ ] **Step 2: Commit**

```bash
git add test/skill_kit_test.exs
git commit -m "refactor: migrate skill_kit_test.exs to SkillKit.Test helpers"
```

---

### Task 8: Migrate `server_test.exs` to New Helpers

**Files:**
- Modify: `test/skill_kit/agent/server_test.exs`

This is the largest migration. Work through each describe block:

- [ ] **Step 1: Replace shared setup with `start_server/1`**

The current `setup` block (lines 13-28) creates a unique registry, agent name, and definition manually. Replace with `start_server/1`. Tests that need custom definitions pass `:definition` override.

- [ ] **Step 2: Migrate "agent loop" tests**

- **"streams LLM response and appends to conversation"** (line 43): Replace SSE events with `expect_response(%Text{...})`. Add `caller: self()` to server opts. Replace `Process.sleep(50)` + `:sys.get_state` with `assert_receive {:skill_kit, _, {:response, _}}` then `:sys.get_state`.

- **"executes local tool calls and loops"** (line 90): Replace with `expect_responses([%ToolCall{...}, %Text{...}])`. Add `caller: self()`. Replace `Process.sleep(100)` with `assert_receive {:skill_kit, _, {:response, _}}`.

- [ ] **Step 3: Migrate "LLM error handling" tests**

- **"gracefully handles LLM stream error"** (line 168): Replace with `expect_error(400, "credit balance too low")`. Add `caller: self()`. Replace `Process.sleep(50)` with `assert_receive {:skill_kit, _, {:error, _}}`.

- **"passes system_prompt and model to LLM"** (line 192): Use `assert_response(%Text{...}, fn ...)` to verify opts. Add `caller: self()`. Replace `Process.sleep(50)` with `assert_receive`.

- [ ] **Step 4: Migrate "tools from kits" test**

Replace SSE events with `assert_response(%Text{...}, fn ...)` to verify tools in opts. Add `caller: self()`. Replace `Process.sleep(50)` with `assert_receive`.

- [ ] **Step 5: Migrate "caller streaming" tests**

These already use `caller: self()` and `assert_receive` — no sleep to remove. Replace SSE events with `expect_response`/`expect_responses`.

- [ ] **Step 6: Migrate "halted state" test**

**Remove `Process.sleep(50)` — no replacement needed.** `:sys.get_state(pid)` is a synchronous GenServer call. Since GenServer processes messages sequentially, it queues behind the `{:mailbox_flush, _}` sent via `send/2`. The halted handler returns `{:noreply, state}` immediately, so `:sys.get_state` sees the post-flush state deterministically.

- [ ] **Step 7: Migrate "builtins" tests**

- **"report_result sends to parent and halts server"** (line 458): Replace SSE events with `expect_response(%ToolCall{...})`. Keep `assert_receive {:subagent_result, ...}` as sync point. Remove `Process.sleep(50)` before `:sys.get_state` — the `assert_receive` already confirms the turn completed, and `:sys.get_state` queues behind any remaining handle_info processing.

- **"report_result with missing parent"** (line 521): Replace SSE events with `expect_response(%ToolCall{...})`. **Remove `Process.sleep(100)` — no replacement needed.** There is no caller and no event to wait on, but `:sys.get_state(pid)` is a synchronous GenServer call that queues behind the `handle_info({:mailbox_flush, _})`. Since the flush processes synchronously (LLM mock returns immediately, tool execution is synchronous, halting is synchronous), `:sys.get_state` will see the final state.

- [ ] **Step 8: Migrate "subagent lifecycle" and "subagent result handling" tests**

Replace SSE events with `expect_response(%Text{...})` or `assert_response(%Text{...}, fn ...)`. These already use `caller: self()` where needed. Replace any remaining `Process.sleep(50)` with `assert_receive` sync points.

- [ ] **Step 9: Run all server tests**

Run: `mix test test/skill_kit/agent/server_test.exs --trace`
Expected: PASS

- [ ] **Step 10: Run full suite**

Run: `mix test`
Expected: All tests pass

- [ ] **Step 11: Verify Process.sleep is gone from server tests**

Run: `grep -n "Process.sleep" test/skill_kit/agent/server_test.exs`
Expected: No matches

- [ ] **Step 12: Commit**

```bash
git add test/skill_kit/agent/server_test.exs
git commit -m "refactor: migrate server_test.exs to SkillKit.Test helpers, remove all Process.sleep"
```

---

### Task 9: Final Verification

- [ ] **Step 1: Run full precommit pipeline**

Run: `mix precommit`
Expected: All steps pass (compile --warnings-as-errors, deps.unlock --unused, format, credo --strict, test)

- [ ] **Step 2: Verify no Process.sleep in server test file**

Run: `grep -n "Process.sleep" test/skill_kit/agent/server_test.exs`
Expected: No matches

Run: `grep -n "Process.sleep" test/skill_kit_test.exs`
Expected: Only matches for OTP shutdown waits (after `stop_agent`) and async `save_conversation` — never for LLM response waits

- [ ] **Step 3: Commit any formatting fixes**

If `mix format` made changes during precommit:

```bash
git add -A
git commit -m "style: format after precommit"
```
