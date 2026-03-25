# Test Helpers & Synchronous send_message Design

## Problem

SkillKit tests use `Process.sleep` as a non-deterministic wait for async turn completion. Every consumer (human, AI agent, or test) must write their own receive loop to get an agent's response. Test files repeat the same SSE event construction, Mox setup, and registry scaffolding 15+ times.

## Design

### 1. `send_message_sync/3`

A synchronous convenience that sends a message and blocks until the turn completes. Does a `receive` directly in the calling process — no Task, no extra process.

```elixir
@spec send_message_sync(agent(), String.t(), timeout()) ::
  {:ok, String.t() | nil} | {:error, term()}
def send_message_sync(agent, content, timeout \\ 5000) do
  case send_message(agent, content) do
    :ok ->
      receive do
        {:skill_kit, agent_name, {:response, text}} when agent_name == agent.name ->
          {:ok, text}

        {:skill_kit, agent_name, {:error, reason}} when agent_name == agent.name ->
          {:error, reason}
      after
        timeout -> {:error, :timeout}
      end

    {:error, reason} ->
      {:error, reason}
  end
end
```

**`send_message/2` is unchanged** — it stays as `:ok | {:error, :not_found}`. No breaking change. Delta messages still arrive at the caller process between the `send_message` cast and the `receive` matching on `:response`/`:error`, so real-time streaming and sync completion work together naturally.

**Caller requirement:** Must be called from the process registered as `caller` in `start_agent/2`, since that's where the Server sends events. This is already the natural pattern.

**Timeout:** Defaults to 5000ms. Returns `{:error, :timeout}` if the turn doesn't complete. Covers the halted server case — if the server is halted and ignores the message, the caller gets a clean timeout instead of hanging. Note: a halted server and a slow LLM call are indistinguishable from the caller's perspective — both produce `{:error, :timeout}`.

**Mailbox behavior:** The `receive` selectively matches only `:response` and `:error` events. Intermediate messages (`:delta`, `:tool_call`, `:tool_result`) arrive in the caller's mailbox but are not consumed by `send_message_sync`. They remain in the mailbox after the function returns. For tests this is harmless (the process exits after the test). Production callers who also need to process intermediate events should use `send_message/2` with their own receive loop instead.

### 2. `SkillKit.Test` Module

Ships in `lib/skill_kit/test.ex`. Available to consumers as part of the `:skill_kit` dependency. Two composable layers.

#### Setup Helper

```elixir
use SkillKit.Test
```

Expands to:

```elixir
import SkillKit.Test
setup :verify_on_exit!
```

Imports the test helpers and sets up Mox verification. Does not import Mox directly — consumers who need `expect/3` or `allow/3` for custom scenarios import Mox themselves. Does not call `setup :set_mox_global` — that's only needed for integration tests through `start_agent` and consumers add it explicitly when needed.

#### Layer 1: SSE Event Builders

Primitives that construct Anthropic SSE event lists. For consumers who need fine-grained control or custom scenarios.

```elixir
SkillKit.Test.text_events("Hi there!")
# => [%{"type" => "message_start", ...}, ..., %{"type" => "message_stop"}]

SkillKit.Test.tool_call_events("echo", %{"command" => "echo hi"})
# => [%{"type" => "message_start", ...}, tool_use blocks, ..., %{"type" => "message_stop"}]
```

`text_events/1` builds the full 6-event sequence from a string:
1. `message_start` — with generated message id
2. `content_block_start` — index 0, type text
3. `content_block_delta` — index 0, text_delta with the content
4. `content_block_stop` — index 0
5. `message_delta` — stop_reason end_turn
6. `message_stop`

`tool_call_events/2` builds the tool_use variant:
1. `message_start` — with generated message id
2. `content_block_start` — index 0, type tool_use, with generated tool call id, name, empty input
3. `content_block_delta` — index 0, input_json_delta with JSON-encoded input
4. `content_block_stop` — index 0
5. `message_delta` — stop_reason tool_use
6. `message_stop`

Both return plain lists of maps. The consumer wraps them in a Mox expectation however they want.

#### Response Types (first-class in `lib/`)

Response types are structs that describe what an LLM returns. They live in `lib/skill_kit/response/` as first-class library types — usable in production code, not just tests. They implement the `SkillKit.Response.Respondable` protocol.

##### Structs

```elixir
defmodule SkillKit.Response.Text do
  @type t :: %__MODULE__{content: String.t()}
  @enforce_keys [:content]
  defstruct [:content]
end

defmodule SkillKit.Response.ToolCall do
  @type t :: %__MODULE__{name: String.t(), input: map()}
  @enforce_keys [:name, :input]
  defstruct [:name, :input]
end

defmodule SkillKit.Response.Error do
  @type t :: %__MODULE__{status: integer(), message: String.t()}
  @enforce_keys [:status, :message]
  defstruct [:status, :message]
end
```

Each struct describes one LLM response. Pure data — no assertion or test logic.

##### `SkillKit.Response.Respondable` Protocol

```elixir
defprotocol SkillKit.Response.Respondable do
  @spec to_stream(t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def to_stream(response)
end
```

Implementations:
- `Text` — builds text SSE events via `SkillKit.Test.text_events/1`, wraps in `{:ok, Stream.map(events, & &1)}`
- `ToolCall` — builds tool_use SSE events via `SkillKit.Test.tool_call_events/2`, wraps in `{:ok, Stream.map(events, & &1)}`
- `Error` — returns `{:error, {status, message}}` directly (no SSE events)

The protocol bridge between response types and the SSE layer lives in test for now (the `Respondable` implementations call test event builders). As the library grows, `to_stream/1` could be used by mock providers or test harnesses in production code.

#### Layer 2: Test Response Helpers

Convenience functions in `SkillKit.Test` that wire up Mox expectations using response types and Layer 1 internally.

##### `expect_response/1`

Sets up a single Mox expectation for one LLM call. No assertions.

```elixir
alias SkillKit.Response.{Text, ToolCall}

expect_response(%Text{content: "Hi there!"})
expect_response(%ToolCall{name: "echo", input: %{"command" => "echo hi"}})
```

Internally calls `Respondable.to_stream/1` and sets up `Mox.expect(SkillKit.LLM.Mock, :stream, 1, ...)`.

##### `assert_response/2`

Sets up a single Mox expectation that runs an assertion callback before returning the response. The callback receives `(messages, opts)` — the arguments the LLM mock was called with.

```elixir
assert_response(%Text{content: "4"}, fn _messages, opts ->
  assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"
end)

assert_response(%ToolCall{name: "echo", input: %{"command" => "echo hi"}}, fn messages, _opts ->
  assert length(messages) == 1
end)
```

Separating assertion from response type keeps structs as pure data. Consumers who don't need assertions use `expect_response/1`. Consumers who need to verify what was sent to the LLM use `assert_response/2`.

##### `expect_responses/1`

Sets up a multi-call Mox expectation from a list of response type structs. Each element corresponds to one `LLM.stream` call in order. For the no-assertion case.

```elixir
expect_responses([
  %ToolCall{name: "echo", input: %{"command" => "echo hi"}},
  %Text{content: "Done!"}
])
```

Internally sets up `Mox.expect(SkillKit.LLM.Mock, :stream, n, ...)` where `n` is the number of steps. Uses `:counters` to track which step to serve on each call.

For multi-turn with per-step assertions, use sequential `assert_response/2` calls — Mox stacks expectations naturally:

```elixir
assert_response(%ToolCall{name: "echo", input: %{"command" => "echo hi"}}, fn messages, _opts ->
  assert length(messages) == 1
end)

assert_response(%Text{content: "Done!"}, fn messages, _opts ->
  assert Enum.any?(messages, &match?(%Message.ToolResult{}, &1))
end)
```

##### `expect_error/2`

Convenience shorthand for `expect_response(%Error{...})`.

```elixir
expect_error(500, "internal error")
```

### 3. Agent Scaffolding

For unit tests that need a bare Server process (not the full agent tree):

```elixir
{:ok, pid, context} = SkillKit.Test.start_server(caller: self())
# context => %{registry: registry_name, agent_name: agent_name, definition: definition}
```

Internally:
1. Creates a unique registry name and starts it via `start_supervised!`
2. Generates a unique agent name
3. Builds a minimal `%Definition{}` with sensible defaults
4. Starts the Server and allows the LLM mock from the test process to the server pid

Returns `{:ok, server_pid, context}`. The context map contains the registry, agent name, and definition for use in assertions.

Options:
- `:caller` — pid to receive events (default: `self()`)
- `:definition` — override the default definition
- `:agent_name` — override the generated name
- `:kits` — kits to pass to the server
- `:scope` — authorization scopes

For integration tests, `SkillKit.start_agent/2` is already clean — no helper needed.

## Scope

### In scope

- `send_message_sync/3` on the `SkillKit` module
- `SkillKit.Response.Text`, `SkillKit.Response.ToolCall`, `SkillKit.Response.Error` structs (first-class library types)
- `SkillKit.Response.Respondable` protocol
- `SkillKit.Test` module with event builders and response helpers
- `SkillKit.Test.start_server/1` scaffolding helper
- `use SkillKit.Test` setup macro
- Remove all `Process.sleep` from existing tests
- Update existing tests to use new helpers

### Out of scope

- Changing `send_message/2` return type (stays `:ok`)
- Changing the Server's internal architecture
- Property-based test generators (stream_data integration)
- Bypass/HTTP-level test helpers (Anthropic client tests stay as-is)
- Phoenix-specific test helpers (LiveView, PubSub)

## Breaking Changes

None. `send_message/2` is unchanged. `send_message_sync/3` and `SkillKit.Test` are purely additive.

## Testing Strategy

- **Unit**: `text_events/1` and `tool_call_events/2` produce valid SSE event structures that `Decoder.decode_events/1` can parse into correct `%Message.Assistant{}` structs
- **Unit**: `expect_response/1` sets up working Mox expectations (mock returns correct stream)
- **Unit**: `expect_responses/1` handles multi-turn counter logic (each call returns the right step)
- **Unit**: `start_server/1` returns a live, registered Server pid with mock allowed
- **Integration**: `send_message_sync/3` blocks and returns `{:ok, text}` for a text response
- **Integration**: `send_message_sync/3` returns `{:error, reason}` for LLM errors
- **Integration**: `send_message_sync/3` returns `{:error, :timeout}` when server is halted
- **Integration**: Deltas arrive at caller before `send_message_sync` returns
- **Migration**: All existing tests converted to use new helpers, zero `Process.sleep` remaining

## File Changes

- Modify: `lib/skill_kit.ex` — add `send_message_sync/3`
- Create: `lib/skill_kit/response/text.ex` — `SkillKit.Response.Text` struct
- Create: `lib/skill_kit/response/tool_call.ex` — `SkillKit.Response.ToolCall` struct
- Create: `lib/skill_kit/response/error.ex` — `SkillKit.Response.Error` struct
- Create: `lib/skill_kit/response/respondable.ex` — `SkillKit.Response.Respondable` protocol + implementations
- Create: `lib/skill_kit/test.ex` — `SkillKit.Test` module with event builders, response helpers, scaffolding, `__using__` macro
- Modify: `test/skill_kit_test.exs` — use `send_message_sync` and helpers
- Modify: `test/skill_kit/agent/server_test.exs` — use helpers, remove sleeps
