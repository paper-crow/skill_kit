# LLM Provider Boundary Design

## Problem

The Server directly calls `SkillKit.LLM.Anthropic.Decoder` to parse raw SSE event maps. This couples the Server to Anthropic's streaming format, makes the LLM mock return Anthropic-specific data, and prevents adding new providers without changing the Server.

Additionally, SSE events are untyped maps (`%{"type" => "content_block_delta", ...}`), caller messages use ad-hoc tuples (`{:skill_kit, name, {:delta, text}}`), and conversation message types live in a deeply nested namespace (`SkillKit.LLM.Message.User`).

## Design

### Dependency Direction

```
Anthropic (standalone, knows nothing about SkillKit)
    ↑
SkillKit (depends on Anthropic, defines protocol implementations)
```

- `Anthropic` is a standalone client library. Returns Anthropic-typed events. Zero SkillKit references.
- `SkillKit` defines protocol implementations that convert Anthropic types into SkillKit types.

### Anthropic Layer

`Anthropic.stream/2` is the public API. Returns `{:ok, stream of %Anthropic.Event.*{}}`. `Anthropic.Client` is internal — never called from outside the `Anthropic` namespace.

Currently `Anthropic.stream/2` does not exist — the current entry point is `SkillKit.LLM.Anthropic.stream/2` which calls `Anthropic.Client.stream/3` directly. This refactor creates a proper `Anthropic` module (`lib/anthropic.ex`) as the public API, with `Client` as an internal detail.

The current raw SSE maps become typed structs:

```elixir
%Anthropic.Event.MessageStart{id: "msg_1", usage: %{input_tokens: 42}}
%Anthropic.Event.ContentBlockStart{index: 0, content_block: %{type: :text}}
%Anthropic.Event.ContentBlockStart{index: 0, content_block: %{type: :tool_use, id: "tc_1", name: "echo"}}
%Anthropic.Event.ContentBlockDelta{index: 0, delta: %{type: :text_delta, text: "Hi"}}
%Anthropic.Event.ContentBlockDelta{index: 0, delta: %{type: :input_json_delta, partial_json: "{\"cmd\":"}}
%Anthropic.Event.ContentBlockStop{index: 0}
%Anthropic.Event.MessageDelta{stop_reason: :end_turn, usage: %{output_tokens: 10}}
%Anthropic.Event.MessageStop{}
```

These mirror Anthropic's SSE event types 1:1. The client parses JSON into these structs. `Anthropic.stream/2` wraps the client, handles config/auth, and returns the typed stream.

### Protocol

`SkillKit.Event.Streamable` — converts provider events into SkillKit events. Takes a provider event + accumulator, returns `{[SkillKit.Event.*], new_acc}`.

```elixir
defprotocol SkillKit.Event.Streamable do
  @spec to_events(t(), acc :: map()) :: {[struct()], map()}
  def to_events(event, acc)
end
```

SkillKit defines the implementations for Anthropic types. The accumulator tracks block metadata needed for multi-event sequences:

```elixir
# Accumulator structure:
# %{
#   blocks: %{0 => %{type: :tool_use, id: "tc_1", name: "echo"}},
#   partial_json: %{0 => "{\"cmd\":\"ls\"}"},
#   usage: %{input_tokens: 0, output_tokens: 0}
# }
```

#### ContentBlockStart

```elixir
defimpl SkillKit.Event.Streamable, for: Anthropic.Event.ContentBlockStart do
  def to_events(%{index: idx, content_block: %{type: :tool_use, id: id, name: name}}, acc) do
    acc = put_in(acc, [:blocks, idx], %{type: :tool_use, id: id, name: name})
    {[%SkillKit.Event.ToolCallStart{id: id, name: name}], acc}
  end

  def to_events(%{index: idx, content_block: %{type: :text}}, acc) do
    acc = put_in(acc, [:blocks, idx], %{type: :text})
    {[], acc}
  end
end
```

#### ContentBlockDelta

```elixir
defimpl SkillKit.Event.Streamable, for: Anthropic.Event.ContentBlockDelta do
  def to_events(%{delta: %{type: :text_delta, text: text}}, acc) do
    {[%SkillKit.Event.Delta{text: text}], acc}
  end

  def to_events(%{index: idx, delta: %{type: :input_json_delta, partial_json: json}}, acc) do
    acc = Map.update(acc, :partial_json, %{idx => json}, fn pj ->
      Map.update(pj, idx, json, &(&1 <> json))
    end)
    {[], acc}
  end
end
```

#### ContentBlockStop

```elixir
defimpl SkillKit.Event.Streamable, for: Anthropic.Event.ContentBlockStop do
  def to_events(%{index: idx}, acc) do
    block = get_in(acc, [:blocks, idx])

    case block do
      %{type: :tool_use, id: id, name: name} ->
        json = get_in(acc, [:partial_json, idx]) || "{}"
        input = Jason.decode!(json)
        {[%SkillKit.Event.ToolCallComplete{id: id, name: name, input: input}], acc}

      _ ->
        {[], acc}
    end
  end
end
```

#### MessageStart / MessageDelta / MessageStop

```elixir
defimpl SkillKit.Event.Streamable, for: Anthropic.Event.MessageStart do
  def to_events(%{usage: usage}, acc) when is_map(usage) do
    {[%SkillKit.Event.Usage{input_tokens: usage[:input_tokens], output_tokens: 0}], acc}
  end

  def to_events(_, acc), do: {[], acc}
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.MessageDelta do
  def to_events(%{stop_reason: reason, usage: usage}, acc) do
    events = [
      %SkillKit.Event.Usage{input_tokens: 0, output_tokens: usage[:output_tokens] || 0},
      %SkillKit.Event.Done{stop_reason: reason}
    ]
    {events, acc}
  end

  def to_events(%{stop_reason: reason}, acc) do
    {[%SkillKit.Event.Done{stop_reason: reason}], acc}
  end
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.MessageStop do
  def to_events(_, acc), do: {[], acc}
end
```

Usage is emitted twice — partial counts from `MessageStart` (input tokens) and `MessageDelta` (output tokens). The Server merges them. This avoids accumulator complexity and lets the caller observe usage as it arrives.

### SkillKit Event Types

Stream events — things happening during an LLM call. All have an `agent` field that is `nil` from the stream and stamped by the Server before forwarding to the caller.

```elixir
%SkillKit.Event.Delta{agent: nil, text: "Hi"}
%SkillKit.Event.ToolCallStart{agent: nil, id: "tc_1", name: "echo"}
%SkillKit.Event.ToolCallComplete{agent: nil, id: "tc_1", name: "echo", input: %{"cmd" => "ls"}}
%SkillKit.Event.Usage{agent: nil, input_tokens: 42, output_tokens: 10}
%SkillKit.Event.Done{agent: nil, stop_reason: :end_turn}
%SkillKit.Event.Error{agent: nil, reason: {500, "boom"}}
```

These events are semantically universal — any streaming LLM provider (Anthropic, OpenAI, Google) can emit them regardless of wire format differences. The protocol implementation for each provider handles the mapping from provider-specific events to these universal events.

### SkillKit Types

Conversation data structures — renamed from `SkillKit.LLM.Message.*`. All have an `agent` field (`nil` in conversation history, stamped when sent to caller).

```elixir
%SkillKit.Types.UserMessage{agent: nil, content: "hello"}
%SkillKit.Types.AssistantMessage{agent: nil, content: "Hi there!", tool_calls: []}
%SkillKit.Types.SystemMessage{agent: nil, content: "You are helpful."}
%SkillKit.Types.ToolCall{id: "tc_1", name: "echo", input: %{"cmd" => "ls"}}
%SkillKit.Types.ToolResult{agent: nil, tool_call_id: "tc_1", content: "hi", is_error: false}
```

The conversation history is a list of these types.

### Caller Message Format

Callers receive structs directly in their mailbox — no wrapper tuples:

```elixir
receive do
  %SkillKit.Event.Delta{agent: "neve", text: text} -> IO.write(text)
  %SkillKit.Types.AssistantMessage{agent: "neve", content: text} -> IO.puts("Done.")
  %SkillKit.Event.Error{agent: "neve", reason: reason} -> IO.puts("Error")
end
```

The Server stamps the `agent` field on all structs before sending.

`send_message_sync/3` updates accordingly:

```elixir
defp await_response(agent_name, timeout) do
  receive do
    %SkillKit.Types.AssistantMessage{agent: ^agent_name} = msg -> {:ok, msg}
    %SkillKit.Event.Error{agent: ^agent_name, reason: reason} -> {:error, reason}
  after
    timeout -> {:error, :timeout}
  end
end
```

Returns `{:ok, %AssistantMessage{}}` instead of `{:ok, text}`.

### LLM Behaviour

The callback signature stays the same:

```elixir
@callback stream(messages :: [message()], opts :: keyword()) ::
  {:ok, Enumerable.t()} | {:error, term()}
```

But the stream now yields `SkillKit.Event.*` structs instead of raw maps. Each provider's adapter (e.g., `SkillKit.LLM.Anthropic`) calls the provider's public API, maps through the protocol, and returns the SkillKit event stream.

```elixir
# lib/skill_kit/llm/anthropic.ex
defmodule SkillKit.LLM.Anthropic do
  @behaviour SkillKit.LLM

  @impl true
  def stream(messages, opts) do
    encoded = encode_messages(messages)

    case Anthropic.stream(encoded, opts) do
      {:ok, raw_stream} ->
        {:ok, to_skill_kit_stream(raw_stream)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_skill_kit_stream(raw_stream) do
    Stream.transform(raw_stream, %{blocks: %{}, partial_json: %{}, usage: %{}}, fn event, acc ->
      SkillKit.Event.Streamable.to_events(event, acc)
    end)
  end
end
```

### Server Changes

The Server's `run_agent_loop` replaces `Decoder` calls with direct reduction over SkillKit events:

- `Decoder.new_accumulator()` → `%{text: "", tool_calls: [], usage: %{input_tokens: 0, output_tokens: 0}}`
- `stream_event/3` → pattern match on `%Event.Delta{}`, `%Event.ToolCallComplete{}`, `%Event.Usage{}`, `%Event.Done{}`
- `Decoder.finalize(acc)` → build `%AssistantMessage{}` from accumulated state

The `stream_event/3` function:

```elixir
defp stream_event(%Event.Delta{text: text}, acc, state) do
  notify_caller(state, %Event.Delta{text: text, agent: state.agent_name})
  %{acc | text: acc.text <> text}
end

defp stream_event(%Event.ToolCallComplete{} = tc, acc, state) do
  notify_caller(state, %{tc | agent: state.agent_name})
  tool_call = %SkillKit.Types.ToolCall{id: tc.id, name: tc.name, input: tc.input}
  %{acc | tool_calls: acc.tool_calls ++ [tool_call]}
end

defp stream_event(%Event.Usage{} = usage, acc, _state) do
  merged = %{
    input_tokens: acc.usage.input_tokens + usage.input_tokens,
    output_tokens: acc.usage.output_tokens + usage.output_tokens
  }
  %{acc | usage: merged}
end

defp stream_event(%Event.Done{}, acc, _state), do: acc
defp stream_event(%Event.ToolCallStart{} = e, acc, state) do
  notify_caller(state, %{e | agent: state.agent_name})
  acc
end
```

### Test Impact

The LLM mock returns SkillKit events directly — no SSE events, no `to_stream`, no provider coupling:

```elixir
def expect_response(%SkillKit.Response.Text{content: text}) do
  events = [
    %SkillKit.Event.Delta{text: text},
    %SkillKit.Event.Done{stop_reason: :end_turn}
  ]

  Mox.expect(SkillKit.LLM.Mock, :stream, 1, fn _messages, _opts ->
    {:ok, Stream.map(events, & &1)}
  end)
end
```

`Anthropic.Test` event builders stay for testing the Anthropic client and protocol implementations. `SkillKit.Test` helpers become genuinely provider-agnostic.

### Naming Changes Summary

| Old | New |
|-----|-----|
| `SkillKit.LLM.Message.User` | `SkillKit.Types.UserMessage` |
| `SkillKit.LLM.Message.Assistant` | `SkillKit.Types.AssistantMessage` |
| `SkillKit.LLM.Message.System` | `SkillKit.Types.SystemMessage` |
| `SkillKit.LLM.Message.ToolCall` | `SkillKit.Types.ToolCall` |
| `SkillKit.LLM.Message.ToolResult` | `SkillKit.Types.ToolResult` |
| `{:skill_kit, name, {:delta, text}}` | `%SkillKit.Event.Delta{agent: name, text: text}` |
| `{:skill_kit, name, {:response, text}}` | `%SkillKit.Types.AssistantMessage{agent: name, content: text}` |
| `{:skill_kit, name, {:error, reason}}` | `%SkillKit.Event.Error{agent: name, reason: reason}` |
| `{:skill_kit, name, {:tool_call, n, i}}` | `%SkillKit.Event.ToolCallComplete{agent: name, ...}` |
| `{:skill_kit, name, {:tool_result, ...}}` | `%SkillKit.Types.ToolResult{agent: name, ...}` |

## Scope

### In scope

- `Anthropic` public API module (`lib/anthropic.ex`) wrapping `Anthropic.Client`
- Anthropic event structs (`Anthropic.Event.*`)
- `SkillKit.Event.Streamable` protocol + implementations for Anthropic types
- SkillKit event structs (`SkillKit.Event.*`)
- SkillKit type renames (`SkillKit.Types.*`)
- Caller message format change (tuples → structs with `agent` field)
- `send_message_sync/3` updated to return `{:ok, %AssistantMessage{}}` and match on struct
- Server updated to work with SkillKit events instead of Decoder
- LLM adapter (`SkillKit.LLM.Anthropic`) wires provider stream through protocol
- Encoder updated for renamed types
- Test helpers updated to return SkillKit events directly
- `Anthropic.Test` event builders stay for Anthropic-level testing
- All existing tests updated

### Out of scope

- Adding new providers (OpenAI, Google) — this creates the foundation
- Changing the `SkillKit.LLM` behaviour callback signature

## Breaking Changes

- Caller message format: tuples → structs (all consumers must update `receive` blocks)
- Message type names: `SkillKit.LLM.Message.*` → `SkillKit.Types.*`
- LLM stream contents: raw maps → `SkillKit.Event.*` structs
- `send_message_sync/3` returns `{:ok, %AssistantMessage{}}` instead of `{:ok, text}`

All acceptable at 0.1.0 with no external consumers.

## Testing Strategy

- **Unit**: Anthropic event structs parse from JSON correctly
- **Unit**: Protocol implementations convert each Anthropic event type to correct SkillKit events
- **Unit**: Protocol handles partial JSON accumulation for tool calls across multiple `ContentBlockDelta` events
- **Unit**: `ContentBlockStop` for tool_use emits `ToolCallComplete` with parsed input from accumulator
- **Unit**: `ContentBlockStart` for tool_use emits `ToolCallStart` with id and name
- **Unit**: `MessageStart` emits `Usage` with input tokens, `MessageDelta` emits `Usage` with output tokens and `Done` with stop reason
- **Unit**: Server reduces SkillKit events into AssistantMessage correctly
- **Integration**: Full agent lifecycle with mock returning SkillKit events
- **Integration**: `send_message_sync/3` returns `{:ok, %AssistantMessage{}}` with struct-based caller messages
- **Migration**: All existing tests updated, zero references to old tuple format or Decoder

## File Changes

### Create
- `lib/anthropic.ex` — `Anthropic` public API module with `stream/2`
- `lib/anthropic/event/message_start.ex` — `Anthropic.Event.MessageStart` struct
- `lib/anthropic/event/content_block_start.ex` — `Anthropic.Event.ContentBlockStart` struct
- `lib/anthropic/event/content_block_delta.ex` — `Anthropic.Event.ContentBlockDelta` struct
- `lib/anthropic/event/content_block_stop.ex` — `Anthropic.Event.ContentBlockStop` struct
- `lib/anthropic/event/message_delta.ex` — `Anthropic.Event.MessageDelta` struct
- `lib/anthropic/event/message_stop.ex` — `Anthropic.Event.MessageStop` struct
- `lib/skill_kit/event/delta.ex` — `SkillKit.Event.Delta` struct
- `lib/skill_kit/event/tool_call_start.ex` — `SkillKit.Event.ToolCallStart` struct
- `lib/skill_kit/event/tool_call_complete.ex` — `SkillKit.Event.ToolCallComplete` struct
- `lib/skill_kit/event/usage.ex` — `SkillKit.Event.Usage` struct
- `lib/skill_kit/event/done.ex` — `SkillKit.Event.Done` struct
- `lib/skill_kit/event/error.ex` — `SkillKit.Event.Error` struct
- `lib/skill_kit/event/streamable.ex` — protocol definition
- `lib/skill_kit/event/streamable/anthropic.ex` — protocol implementations for Anthropic types
- `lib/skill_kit/types/user_message.ex` — renamed from `Message.User`
- `lib/skill_kit/types/assistant_message.ex` — renamed from `Message.Assistant`
- `lib/skill_kit/types/system_message.ex` — renamed from `Message.System`
- `lib/skill_kit/types/tool_call.ex` — renamed from `Message.ToolCall`
- `lib/skill_kit/types/tool_result.ex` — renamed from `Message.ToolResult`

### Modify
- `lib/anthropic/client.ex` — parse JSON into `Anthropic.Event.*` structs instead of raw maps
- `lib/skill_kit/llm/anthropic.ex` — wire `Anthropic.stream/2` through protocol, update encoder for renamed types
- `lib/skill_kit/llm/anthropic/encoder.ex` — update references from `Message.*` to `Types.*`
- `lib/skill_kit/agent/server.ex` — replace Decoder with SkillKit event pattern matching, send structs to caller
- `lib/skill_kit.ex` — update `send_message_sync` for struct-based messages
- `lib/skill_kit/test.ex` — return SkillKit events from mock helpers
- `lib/skill_kit/agent/agent.ex` — update Message references to Types
- `lib/skill_kit/agent/tool_builder.ex` — update Message references to Types
- `test/skill_kit/agent/server_test.exs` — update for new event types and caller format
- `test/skill_kit_test.exs` — update for new caller format
- `test/skill_kit/test_test.exs` — update for new mock format
- `test/skill_kit/llm/anthropic/encoder_test.exs` — update Message references
- `test/anthropic/test_test.exs` — stays, tests Anthropic event builders
- All other test files referencing `Message.*` types

### Delete
- `lib/skill_kit/llm/anthropic/decoder.ex` — replaced by protocol + Server reduction
- `lib/skill_kit/llm/message.ex` — replaced by `SkillKit.Types.*`
- `test/skill_kit/llm/anthropic/decoder_test.exs` — replaced by protocol implementation tests
