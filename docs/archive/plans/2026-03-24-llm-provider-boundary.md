# LLM Provider Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decouple the Server from Anthropic's SSE format by introducing typed events at every layer — Anthropic event structs, a Streamable protocol, universal SkillKit events, and struct-based caller messages.

**Architecture:** Anthropic is a standalone client returning typed events. SkillKit defines a `Streamable` protocol that converts Anthropic events to SkillKit events. The Server works only with SkillKit events. Callers receive structs, not tuples.

**Tech Stack:** Elixir 1.17, ExUnit, Mox, Jason

**Spec:** `@docs/superpowers/specs/2026-03-24-llm-provider-boundary-design.md`

**Code style:** No alias shortcuts (alias each module individually). No single-pipe chains. Prefer capture syntax (`&`) over `fn`. Extract multiline expressions to private helpers. Use recursive function heads to normalize data.

---

## File Structure

| File | Responsibility |
|------|----------------|
| **SkillKit Types (renames)** | |
| `lib/skill_kit/types/user_message.ex` | `%UserMessage{agent, content}` |
| `lib/skill_kit/types/assistant_message.ex` | `%AssistantMessage{agent, content, tool_calls}` |
| `lib/skill_kit/types/system_message.ex` | `%SystemMessage{agent, content}` |
| `lib/skill_kit/types/tool_call.ex` | `%ToolCall{id, name, input}` |
| `lib/skill_kit/types/tool_result.ex` | `%ToolResult{agent, tool_call_id, content, is_error}` |
| **Anthropic Event structs** | |
| `lib/anthropic/event/message_start.ex` | `%MessageStart{id, usage}` |
| `lib/anthropic/event/content_block_start.ex` | `%ContentBlockStart{index, content_block}` |
| `lib/anthropic/event/content_block_delta.ex` | `%ContentBlockDelta{index, delta}` |
| `lib/anthropic/event/content_block_stop.ex` | `%ContentBlockStop{index}` |
| `lib/anthropic/event/message_delta.ex` | `%MessageDelta{stop_reason, usage}` |
| `lib/anthropic/event/message_stop.ex` | `%MessageStop{}` |
| **SkillKit Event structs** | |
| `lib/skill_kit/event/delta.ex` | `%Delta{agent, text}` |
| `lib/skill_kit/event/tool_call_start.ex` | `%ToolCallStart{agent, id, name}` |
| `lib/skill_kit/event/tool_call_complete.ex` | `%ToolCallComplete{agent, id, name, input}` |
| `lib/skill_kit/event/usage.ex` | `%Usage{agent, input_tokens, output_tokens}` |
| `lib/skill_kit/event/done.ex` | `%Done{agent, stop_reason}` |
| `lib/skill_kit/event/error.ex` | `%Error{agent, reason}` |
| **Protocol** | |
| `lib/skill_kit/event/streamable.ex` | Protocol definition |
| `lib/skill_kit/event/streamable/anthropic.ex` | Implementations for all 6 Anthropic event types |
| **Modified** | |
| `lib/anthropic.ex` | New public API: `Anthropic.stream/2` returning typed events |
| `lib/anthropic/client.ex` | SSE parser returns `%Anthropic.Event.*{}` structs |
| `lib/skill_kit/llm/anthropic.ex` | Adapter wires through Streamable protocol |
| `lib/skill_kit/llm/anthropic/encoder.ex` | Update `Message.*` → `Types.*` references |
| `lib/skill_kit/agent/server.ex` | Replace Decoder with event pattern matching, struct caller messages |
| `lib/skill_kit.ex` | `send_message_sync` returns `{:ok, %AssistantMessage{}}` |
| `lib/skill_kit/test.ex` | Mock returns SkillKit events |
| **Deleted** | |
| `lib/skill_kit/llm/anthropic/decoder.ex` | Replaced by protocol + Server reduction |
| `lib/skill_kit/llm/message.ex` | Replaced by `SkillKit.Types.*` |

---

### Task 1: SkillKit Types — Rename Message Structs

**Files:**
- Create: `lib/skill_kit/types/user_message.ex`
- Create: `lib/skill_kit/types/assistant_message.ex`
- Create: `lib/skill_kit/types/system_message.ex`
- Create: `lib/skill_kit/types/tool_call.ex`
- Create: `lib/skill_kit/types/tool_result.ex`

Create the new types with `agent` fields. Do NOT delete old `Message.*` types yet — they'll be replaced in a later task when all references are updated.

- [ ] **Step 1: Create all 5 type structs**

```elixir
# lib/skill_kit/types/user_message.ex
defmodule SkillKit.Types.UserMessage do
  @moduledoc "A user message in a conversation."

  @type t :: %__MODULE__{
          agent: String.t() | nil,
          content: String.t()
        }

  @enforce_keys [:content]
  defstruct [:agent, :content]
end
```

```elixir
# lib/skill_kit/types/assistant_message.ex
defmodule SkillKit.Types.AssistantMessage do
  @moduledoc "An assistant response in a conversation."

  @type t :: %__MODULE__{
          agent: String.t() | nil,
          content: String.t() | nil,
          tool_calls: [SkillKit.Types.ToolCall.t()]
        }

  defstruct [:agent, :content, tool_calls: []]
end
```

```elixir
# lib/skill_kit/types/system_message.ex
defmodule SkillKit.Types.SystemMessage do
  @moduledoc "A system message in a conversation."

  @type t :: %__MODULE__{
          agent: String.t() | nil,
          content: String.t()
        }

  @enforce_keys [:content]
  defstruct [:agent, :content]
end
```

```elixir
# lib/skill_kit/types/tool_call.ex
defmodule SkillKit.Types.ToolCall do
  @moduledoc "A tool invocation from the assistant."

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          input: map()
        }

  @enforce_keys [:id, :name, :input]
  defstruct [:id, :name, :input]
end
```

```elixir
# lib/skill_kit/types/tool_result.ex
defmodule SkillKit.Types.ToolResult do
  @moduledoc "The result of executing a tool."

  @type t :: %__MODULE__{
          agent: String.t() | nil,
          tool_call_id: String.t(),
          content: String.t(),
          is_error: boolean()
        }

  @enforce_keys [:tool_call_id, :content]
  defstruct [:agent, :tool_call_id, :content, is_error: false]
end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add lib/skill_kit/types/
git commit -m "feat: add SkillKit.Types.* message structs with agent field"
```

---

### Task 2: Anthropic Event Structs

**Files:**
- Create: `lib/anthropic/event/message_start.ex`
- Create: `lib/anthropic/event/content_block_start.ex`
- Create: `lib/anthropic/event/content_block_delta.ex`
- Create: `lib/anthropic/event/content_block_stop.ex`
- Create: `lib/anthropic/event/message_delta.ex`
- Create: `lib/anthropic/event/message_stop.ex`
- Modify: `lib/anthropic/client.ex` — SSE parser returns typed structs
- Create: `lib/anthropic.ex` — public API module
- Test: `test/anthropic/event_test.exs`

- [ ] **Step 1: Create all 6 Anthropic event structs**

```elixir
# lib/anthropic/event/message_start.ex
defmodule Anthropic.Event.MessageStart do
  @moduledoc false
  defstruct [:id, :usage]
end
```

```elixir
# lib/anthropic/event/content_block_start.ex
defmodule Anthropic.Event.ContentBlockStart do
  @moduledoc false
  @enforce_keys [:index, :content_block]
  defstruct [:index, :content_block]
end
```

```elixir
# lib/anthropic/event/content_block_delta.ex
defmodule Anthropic.Event.ContentBlockDelta do
  @moduledoc false
  @enforce_keys [:index, :delta]
  defstruct [:index, :delta]
end
```

```elixir
# lib/anthropic/event/content_block_stop.ex
defmodule Anthropic.Event.ContentBlockStop do
  @moduledoc false
  @enforce_keys [:index]
  defstruct [:index]
end
```

```elixir
# lib/anthropic/event/message_delta.ex
defmodule Anthropic.Event.MessageDelta do
  @moduledoc false
  defstruct [:stop_reason, :usage]
end
```

```elixir
# lib/anthropic/event/message_stop.ex
defmodule Anthropic.Event.MessageStop do
  @moduledoc false
  defstruct []
end
```

- [ ] **Step 2: Add parse function to convert raw JSON maps to structs**

Create a parser module that the client will call:

```elixir
# lib/anthropic/event.ex
defmodule Anthropic.Event do
  @moduledoc false

  alias Anthropic.Event.ContentBlockDelta
  alias Anthropic.Event.ContentBlockStart
  alias Anthropic.Event.ContentBlockStop
  alias Anthropic.Event.MessageDelta
  alias Anthropic.Event.MessageStart
  alias Anthropic.Event.MessageStop

  @spec parse(map()) :: struct()
  def parse(%{"type" => "message_start", "message" => msg}) do
    %MessageStart{id: msg["id"], usage: msg["usage"]}
  end

  def parse(%{"type" => "content_block_start", "index" => idx, "content_block" => cb}) do
    %ContentBlockStart{index: idx, content_block: parse_content_block(cb)}
  end

  def parse(%{"type" => "content_block_delta", "index" => idx, "delta" => delta}) do
    %ContentBlockDelta{index: idx, delta: parse_delta(delta)}
  end

  def parse(%{"type" => "content_block_stop", "index" => idx}) do
    %ContentBlockStop{index: idx}
  end

  def parse(%{"type" => "message_delta", "delta" => delta} = event) do
    %MessageDelta{
      stop_reason: parse_stop_reason(delta["stop_reason"]),
      usage: event["usage"] || delta["usage"]
    }
  end

  def parse(%{"type" => "message_stop"}) do
    %MessageStop{}
  end

  def parse(%{"type" => "ping"}), do: :skip
  def parse(_other), do: :skip

  defp parse_content_block(%{"type" => "text"} = cb) do
    %{type: :text, text: cb["text"]}
  end

  defp parse_content_block(%{"type" => "tool_use"} = cb) do
    %{type: :tool_use, id: cb["id"], name: cb["name"]}
  end

  defp parse_delta(%{"type" => "text_delta"} = d), do: %{type: :text_delta, text: d["text"]}
  defp parse_delta(%{"type" => "input_json_delta"} = d), do: %{type: :input_json_delta, partial_json: d["partial_json"]}
  defp parse_delta(d), do: d

  defp parse_stop_reason("end_turn"), do: :end_turn
  defp parse_stop_reason("tool_use"), do: :tool_use
  defp parse_stop_reason(other), do: other
end
```

- [ ] **Step 3: Write tests for event parsing**

```elixir
# test/anthropic/event_test.exs
defmodule Anthropic.EventTest do
  use ExUnit.Case, async: true

  alias Anthropic.Event
  alias Anthropic.Event.ContentBlockDelta
  alias Anthropic.Event.ContentBlockStart
  alias Anthropic.Event.ContentBlockStop
  alias Anthropic.Event.MessageDelta
  alias Anthropic.Event.MessageStart
  alias Anthropic.Event.MessageStop

  describe "parse/1" do
    test "parses message_start" do
      raw = %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => [], "usage" => %{"input_tokens" => 42}}}

      assert %MessageStart{id: "msg_1", usage: %{"input_tokens" => 42}} = Event.parse(raw)
    end

    test "parses content_block_start for text" do
      raw = %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}}

      assert %ContentBlockStart{index: 0, content_block: %{type: :text}} = Event.parse(raw)
    end

    test "parses content_block_start for tool_use" do
      raw = %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "tool_use", "id" => "tc_1", "name" => "echo"}}

      assert %ContentBlockStart{index: 0, content_block: %{type: :tool_use, id: "tc_1", name: "echo"}} = Event.parse(raw)
    end

    test "parses content_block_delta with text_delta" do
      raw = %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hi"}}

      assert %ContentBlockDelta{index: 0, delta: %{type: :text_delta, text: "Hi"}} = Event.parse(raw)
    end

    test "parses content_block_delta with input_json_delta" do
      raw = %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"cmd\":"}}

      assert %ContentBlockDelta{index: 0, delta: %{type: :input_json_delta, partial_json: "{\"cmd\":"}} = Event.parse(raw)
    end

    test "parses content_block_stop" do
      raw = %{"type" => "content_block_stop", "index" => 0}

      assert %ContentBlockStop{index: 0} = Event.parse(raw)
    end

    test "parses message_delta" do
      raw = %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => 10}}

      assert %MessageDelta{stop_reason: :end_turn, usage: %{"output_tokens" => 10}} = Event.parse(raw)
    end

    test "parses message_stop" do
      raw = %{"type" => "message_stop"}

      assert %MessageStop{} = Event.parse(raw)
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `mix test test/anthropic/event_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Update `Anthropic.Client.sse_stream/1` to parse events into structs**

In `lib/anthropic/client.ex`, the `sse_stream/1` function currently returns raw JSON maps. Add `Anthropic.Event.parse/1` to the pipeline:

Current (line ~108-115):
```elixir
defp sse_stream(async_body) do
  Stream.flat_map(async_body, fn chunk ->
    chunk
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
  end)
end
```

Change to:
```elixir
defp sse_stream(async_body) do
  Stream.flat_map(async_body, fn chunk ->
    chunk
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
    |> Enum.map(&Anthropic.Event.parse/1)
    |> Enum.reject(&(&1 == :skip))
  end)
end
```

- [ ] **Step 6: Create `Anthropic` public API module**

Currently `lib/anthropic/anthropic.ex` exists as a wrapper around `Client`. Rename/update it to be the proper public API at `lib/anthropic.ex`. Read the current file first — it has a `stream/3` that takes `(config, messages, opts)`. Keep the same signature but ensure it returns typed events now (it already does via the client change).

Note: `Anthropic` module already exists at `lib/anthropic/anthropic.ex` with `stream/3` taking `(config, messages, opts)`. Keep the current arity and location — it already works as the public API. The client now returns typed structs, so `Anthropic.stream/3` returns them transparently.

- [ ] **Step 7: Run full test suite**

Run: `mix test`
Expected: Some tests may fail because `Anthropic.Test.text_events/1` returns raw maps but the client now returns structs. The Anthropic test helpers are for testing at the Anthropic level — they should continue to return raw maps since they bypass the client. The client-level tests (`test/anthropic/client_test.exs`) may need updates if they assert on raw maps. Check and fix.

- [ ] **Step 8: Commit**

```bash
git add lib/anthropic/event/ lib/anthropic/event.ex lib/anthropic/client.ex test/anthropic/event_test.exs
git commit -m "feat: add typed Anthropic event structs with parser"
```

---

### Task 3: SkillKit Event Structs

**Files:**
- Create: `lib/skill_kit/event/delta.ex`
- Create: `lib/skill_kit/event/tool_call_start.ex`
- Create: `lib/skill_kit/event/tool_call_complete.ex`
- Create: `lib/skill_kit/event/usage.ex`
- Create: `lib/skill_kit/event/done.ex`
- Create: `lib/skill_kit/event/error.ex`

- [ ] **Step 1: Create all 6 event structs**

```elixir
# lib/skill_kit/event/delta.ex
defmodule SkillKit.Event.Delta do
  @moduledoc "A text fragment from the LLM stream."
  @enforce_keys [:text]
  defstruct [:agent, :text]
end
```

```elixir
# lib/skill_kit/event/tool_call_start.ex
defmodule SkillKit.Event.ToolCallStart do
  @moduledoc "A tool call has begun (name and id known)."
  @enforce_keys [:id, :name]
  defstruct [:agent, :id, :name]
end
```

```elixir
# lib/skill_kit/event/tool_call_complete.ex
defmodule SkillKit.Event.ToolCallComplete do
  @moduledoc "A tool call is fully parsed with input."
  @enforce_keys [:id, :name, :input]
  defstruct [:agent, :id, :name, :input]
end
```

```elixir
# lib/skill_kit/event/usage.ex
defmodule SkillKit.Event.Usage do
  @moduledoc "Token usage counts from the LLM."
  defstruct [:agent, input_tokens: 0, output_tokens: 0]
end
```

```elixir
# lib/skill_kit/event/done.ex
defmodule SkillKit.Event.Done do
  @moduledoc "The LLM turn is complete."
  @enforce_keys [:stop_reason]
  defstruct [:agent, :stop_reason]
end
```

```elixir
# lib/skill_kit/event/error.ex
defmodule SkillKit.Event.Error do
  @moduledoc "An error from the LLM."
  @enforce_keys [:reason]
  defstruct [:agent, :reason]
end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add lib/skill_kit/event/
git commit -m "feat: add SkillKit.Event.* universal event structs"
```

---

### Task 4: Streamable Protocol + Anthropic Implementations

**Files:**
- Create: `lib/skill_kit/event/streamable.ex`
- Create: `lib/skill_kit/event/streamable/anthropic.ex`
- Test: `test/skill_kit/event/streamable_test.exs`

- [ ] **Step 1: Write tests for the protocol**

```elixir
# test/skill_kit/event/streamable_test.exs
defmodule SkillKit.Event.StreamableTest do
  use ExUnit.Case, async: true

  alias Anthropic.Event.ContentBlockDelta
  alias Anthropic.Event.ContentBlockStart
  alias Anthropic.Event.ContentBlockStop
  alias Anthropic.Event.MessageDelta
  alias Anthropic.Event.MessageStart
  alias Anthropic.Event.MessageStop
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.Streamable
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Event.ToolCallStart
  alias SkillKit.Event.Usage

  describe "ContentBlockStart" do
    test "text block emits nothing" do
      event = %ContentBlockStart{index: 0, content_block: %{type: :text}}
      assert {[], _acc} = Streamable.to_events(event, new_acc())
    end

    test "tool_use block emits ToolCallStart" do
      event = %ContentBlockStart{index: 0, content_block: %{type: :tool_use, id: "tc_1", name: "echo"}}
      {events, acc} = Streamable.to_events(event, new_acc())

      assert [%ToolCallStart{id: "tc_1", name: "echo"}] = events
      assert acc.blocks[0] == %{type: :tool_use, id: "tc_1", name: "echo"}
    end
  end

  describe "ContentBlockDelta" do
    test "text_delta emits Delta" do
      event = %ContentBlockDelta{index: 0, delta: %{type: :text_delta, text: "Hi"}}
      {events, _acc} = Streamable.to_events(event, new_acc())

      assert [%Delta{text: "Hi"}] = events
    end

    test "input_json_delta accumulates without emitting" do
      event = %ContentBlockDelta{index: 0, delta: %{type: :input_json_delta, partial_json: "{\"cmd\":"}}
      {events, acc} = Streamable.to_events(event, new_acc())

      assert [] = events
      assert acc.partial_json[0] == "{\"cmd\":"
    end

    test "multiple input_json_deltas concatenate" do
      acc = new_acc()
      e1 = %ContentBlockDelta{index: 0, delta: %{type: :input_json_delta, partial_json: "{\"cmd\":"}}
      {[], acc} = Streamable.to_events(e1, acc)

      e2 = %ContentBlockDelta{index: 0, delta: %{type: :input_json_delta, partial_json: "\"ls\"}"}}
      {[], acc} = Streamable.to_events(e2, acc)

      assert acc.partial_json[0] == "{\"cmd\":\"ls\"}"
    end
  end

  describe "ContentBlockStop" do
    test "tool_use block emits ToolCallComplete with parsed JSON input" do
      acc =
        new_acc()
        |> put_in([:blocks, 0], %{type: :tool_use, id: "tc_1", name: "echo"})
        |> put_in([:partial_json, 0], "{\"cmd\":\"ls\"}")

      event = %ContentBlockStop{index: 0}
      {events, _acc} = Streamable.to_events(event, acc)

      assert [%ToolCallComplete{id: "tc_1", name: "echo", input: %{"cmd" => "ls"}}] = events
    end

    test "text block emits nothing" do
      acc = put_in(new_acc(), [:blocks, 0], %{type: :text})
      event = %ContentBlockStop{index: 0}

      assert {[], _acc} = Streamable.to_events(event, acc)
    end
  end

  describe "MessageStart" do
    test "emits Usage with input tokens" do
      event = %MessageStart{id: "msg_1", usage: %{"input_tokens" => 42}}
      {events, _acc} = Streamable.to_events(event, new_acc())

      assert [%Usage{input_tokens: 42, output_tokens: 0}] = events
    end

    test "no usage emits nothing" do
      event = %MessageStart{id: "msg_1", usage: nil}
      assert {[], _acc} = Streamable.to_events(event, new_acc())
    end
  end

  describe "MessageDelta" do
    test "emits Usage and Done" do
      event = %MessageDelta{stop_reason: :end_turn, usage: %{"output_tokens" => 10}}
      {events, _acc} = Streamable.to_events(event, new_acc())

      assert [%Usage{input_tokens: 0, output_tokens: 10}, %Done{stop_reason: :end_turn}] = events
    end

    test "without usage emits only Done" do
      event = %MessageDelta{stop_reason: :tool_use, usage: nil}
      {events, _acc} = Streamable.to_events(event, new_acc())

      assert [%Done{stop_reason: :tool_use}] = events
    end
  end

  describe "MessageStop" do
    test "emits nothing" do
      event = %MessageStop{}
      assert {[], _acc} = Streamable.to_events(event, new_acc())
    end
  end

  defp new_acc, do: %{blocks: %{}, partial_json: %{}}
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/skill_kit/event/streamable_test.exs --trace`
Expected: FAIL — `Streamable` protocol not defined

- [ ] **Step 3: Create protocol definition**

```elixir
# lib/skill_kit/event/streamable.ex
defprotocol SkillKit.Event.Streamable do
  @moduledoc """
  Converts provider-specific events into SkillKit events.

  Each implementation handles one provider event type and may emit
  zero or more SkillKit events. The accumulator carries state needed
  across events (e.g., partial JSON for tool call inputs).
  """

  @spec to_events(t(), map()) :: {[struct()], map()}
  def to_events(event, acc)
end
```

- [ ] **Step 4: Create Anthropic implementations**

```elixir
# lib/skill_kit/event/streamable/anthropic.ex

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.MessageStart do
  alias SkillKit.Event.Usage

  def to_events(%{usage: usage}, acc) when is_map(usage) do
    {[%Usage{input_tokens: usage["input_tokens"] || 0, output_tokens: 0}], acc}
  end

  def to_events(_, acc), do: {[], acc}
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.ContentBlockStart do
  alias SkillKit.Event.ToolCallStart

  def to_events(%{index: idx, content_block: %{type: :tool_use, id: id, name: name}}, acc) do
    acc = put_in(acc, [:blocks, idx], %{type: :tool_use, id: id, name: name})
    {[%ToolCallStart{id: id, name: name}], acc}
  end

  def to_events(%{index: idx, content_block: %{type: :text}}, acc) do
    acc = put_in(acc, [:blocks, idx], %{type: :text})
    {[], acc}
  end
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.ContentBlockDelta do
  alias SkillKit.Event.Delta

  def to_events(%{delta: %{type: :text_delta, text: text}}, acc) do
    {[%Delta{text: text}], acc}
  end

  def to_events(%{index: idx, delta: %{type: :input_json_delta, partial_json: json}}, acc) do
    acc = Map.update(acc, :partial_json, %{idx => json}, fn pj ->
      Map.update(pj, idx, json, &(&1 <> json))
    end)
    {[], acc}
  end
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.ContentBlockStop do
  alias SkillKit.Event.ToolCallComplete

  def to_events(%{index: idx}, acc) do
    case get_in(acc, [:blocks, idx]) do
      %{type: :tool_use, id: id, name: name} ->
        json = get_in(acc, [:partial_json, idx]) || "{}"
        input = Jason.decode!(json)
        {[%ToolCallComplete{id: id, name: name, input: input}], acc}

      _ ->
        {[], acc}
    end
  end
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.MessageDelta do
  alias SkillKit.Event.Done
  alias SkillKit.Event.Usage

  def to_events(%{stop_reason: reason, usage: usage}, acc) when is_map(usage) do
    events = [
      %Usage{input_tokens: 0, output_tokens: usage["output_tokens"] || 0},
      %Done{stop_reason: reason}
    ]
    {events, acc}
  end

  def to_events(%{stop_reason: reason}, acc) do
    {[%Done{stop_reason: reason}], acc}
  end
end

defimpl SkillKit.Event.Streamable, for: Anthropic.Event.MessageStop do
  def to_events(_, acc), do: {[], acc}
end
```

- [ ] **Step 5: Run tests**

Run: `mix test test/skill_kit/event/streamable_test.exs --trace`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add lib/skill_kit/event/streamable.ex lib/skill_kit/event/streamable/ test/skill_kit/event/streamable_test.exs
git commit -m "feat: add Streamable protocol with Anthropic implementations"
```

---

### Task 5: Wire LLM Adapter Through Protocol

**Files:**
- Modify: `lib/skill_kit/llm/anthropic.ex` (currently at `lib/skill_kit/llm/anthropic/anthropic.ex`)
- Modify: `lib/skill_kit/llm/anthropic/encoder.ex`

- [ ] **Step 1: Update the LLM adapter to wire through Streamable**

Read `lib/skill_kit/llm/anthropic/anthropic.ex`. Currently it calls `Anthropic.Client.stream(client, encoded_messages, request_opts)` and returns the raw stream. Change it to map through the Streamable protocol using `Stream.transform/3`:

The adapter's `stream/2` should:
1. Resolve config, build client (keep existing logic)
2. Call `Anthropic.stream(config, encoded_messages, request_opts)` (using the public API, not Client directly)
3. Map the resulting `%Anthropic.Event.*{}` stream through `SkillKit.Event.Streamable.to_events/2`
4. Return `{:ok, skill_kit_event_stream}`

Add this private function:

```elixir
defp to_skill_kit_stream(anthropic_stream) do
  Stream.transform(anthropic_stream, %{blocks: %{}, partial_json: %{}}, fn event, acc ->
    SkillKit.Event.Streamable.to_events(event, acc)
  end)
end
```

And update the success path to: `{:ok, to_skill_kit_stream(stream)}`

Note: Unknown Anthropic events are filtered to `:skip` by `Anthropic.Event.parse/1` and rejected by the client's `Enum.reject`. The adapter stream will only contain valid `%Anthropic.Event.*{}` structs.

- [ ] **Step 2: Update Encoder for new Types (partial)**

Read `lib/skill_kit/llm/anthropic/encoder.ex`. It references `Message.User`, `Message.Assistant`, `Message.System`, `Message.ToolResult`, `Message.ToolCall`. For now, add support for BOTH old and new types by adding new function clauses that match on `SkillKit.Types.*` structs. This allows incremental migration — old code still works while new code can use the new types.

Add these clauses alongside the existing ones:

```elixir
defp encode_message(%SkillKit.Types.UserMessage{content: content}) do
  %{"role" => "user", "content" => content}
end

defp encode_message(%SkillKit.Types.AssistantMessage{content: content, tool_calls: []}) do
  %{"role" => "assistant", "content" => content}
end

defp encode_message(%SkillKit.Types.AssistantMessage{content: content, tool_calls: tool_calls}) do
  # same logic as existing Message.Assistant with tool_calls
end

defp encode_message(%SkillKit.Types.SystemMessage{content: content}) do
  %{"role" => "user", "content" => content}
end
```

Also add `chunk_tool_results` clause for `%SkillKit.Types.ToolResult{}` and `encode_tool_result` for the new type.

- [ ] **Step 3: Run full test suite**

Run: `mix test`
Expected: Most tests PASS — the LLM mock bypasses the adapter entirely, so Server tests are unaffected. The `test/anthropic/client_test.exs` (which uses Bypass for real HTTP) may fail because the client now returns typed structs instead of raw maps — check and update assertions if needed.

- [ ] **Step 4: Commit**

```bash
git add lib/skill_kit/llm/anthropic/anthropic.ex lib/skill_kit/llm/anthropic/encoder.ex
git commit -m "feat: wire LLM adapter through Streamable protocol"
```

---

### Task 6: Server Refactor — SkillKit Events + Struct Caller Messages

**Files:**
- Modify: `lib/skill_kit/agent/server.ex`

This is the largest single task. The Server currently:
1. Reduces the LLM stream through `Decoder.decode_event/2` + `Decoder.finalize/1`
2. Sends tuples like `{:skill_kit, name, {:delta, text}}` to the caller

After this task:
1. Reduces the LLM stream by pattern matching on `%SkillKit.Event.*{}` structs
2. Sends structs directly to the caller

- [ ] **Step 1: Replace Decoder imports with Event/Types aliases**

At the top of `server.ex`, replace:
```elixir
alias SkillKit.LLM.Anthropic.Decoder
alias SkillKit.LLM.Message
```
With:
```elixir
alias SkillKit.Event.Delta
alias SkillKit.Event.Done
alias SkillKit.Event.ToolCallComplete
alias SkillKit.Event.ToolCallStart
alias SkillKit.Event.Usage
alias SkillKit.Types.AssistantMessage
alias SkillKit.Types.ToolCall
alias SkillKit.Types.ToolResult
alias SkillKit.Types.UserMessage
alias SkillKit.Types.SystemMessage
```

Keep `alias SkillKit.LLM.Message` temporarily — other parts of the codebase still reference it during migration.

- [ ] **Step 2: Replace `run_agent_loop` stream processing**

Current (lines ~204-208):
```elixir
case stream(state, tools) do
  {:ok, stream} ->
    acc = Enum.reduce(stream, Decoder.new_accumulator(), &stream_event(&1, &2, state))
    response = Decoder.finalize(acc)
```

Replace with:
```elixir
case stream(state, tools) do
  {:ok, event_stream} ->
    acc = Enum.reduce(event_stream, new_accumulator(), &process_event(&1, &2, state))
    response = finalize(acc)
```

- [ ] **Step 3: Implement `new_accumulator/0`, `process_event/3`, `finalize/1`**

```elixir
defp new_accumulator do
  %{text: "", tool_calls: [], usage: %{input_tokens: 0, output_tokens: 0}}
end

defp process_event(%Delta{text: text}, acc, state) do
  notify_caller(state, %Delta{text: text, agent: state.agent_name})
  %{acc | text: acc.text <> text}
end

defp process_event(%ToolCallStart{} = event, acc, state) do
  notify_caller(state, %{event | agent: state.agent_name})
  acc
end

defp process_event(%ToolCallComplete{} = event, acc, state) do
  notify_caller(state, %{event | agent: state.agent_name})
  tool_call = %ToolCall{id: event.id, name: event.name, input: event.input}
  %{acc | tool_calls: acc.tool_calls ++ [tool_call]}
end

defp process_event(%Usage{} = usage, acc, _state) do
  merged = %{
    input_tokens: acc.usage.input_tokens + usage.input_tokens,
    output_tokens: acc.usage.output_tokens + usage.output_tokens
  }
  %{acc | usage: merged}
end

defp process_event(%Done{}, acc, _state), do: acc
defp process_event(_other, acc, _state), do: acc

defp finalize(acc) do
  content = if acc.text == "", do: nil, else: acc.text

  %AssistantMessage{
    content: content,
    tool_calls: acc.tool_calls
  }
end
```

- [ ] **Step 4: Update `notify_caller/2` to send structs**

Current:
```elixir
defp notify_caller(%{caller: nil}, _event), do: :ok
defp notify_caller(%{caller: caller, agent_name: name}, event) do
  send(caller, {:skill_kit, name, event})
end
```

Change to:
```elixir
defp notify_caller(%{caller: nil}, _event), do: :ok
defp notify_caller(%{caller: caller}, event) do
  send(caller, event)
end
```

The `agent` field is already stamped on the struct before `notify_caller` is called.

- [ ] **Step 5: Update `handle_response/2` to send AssistantMessage struct**

Current sends `{:skill_kit, name, {:response, response.content}}`. Change to send the full `%AssistantMessage{}` with agent stamped:

```elixir
defp handle_response(%AssistantMessage{tool_calls: []} = response, state) do
  notify_caller(state, %{response | agent: state.agent_name})
  state
end
```

- [ ] **Step 6: Update tool call execution to use new types**

The `execute_tool_calls/3` function creates `%Message.ToolResult{}` — update to `%ToolResult{}`. The tool call classifier matches on `tool_call.name` — this should still work since `%ToolCall{}` has the same `name` field.

Also update:
- `handle_builtin/2` which creates `%Message.System{}` — change to `%SystemMessage{}`
- `handle_info({:subagent_result, ...})` (line ~145) which creates `%Message.System{}` — change to `%SystemMessage{}`
- `handle_info({:DOWN, ...})` (line ~180) which creates `%Message.System{}` — change to `%SystemMessage{}`

- [ ] **Step 7: Update `handle_info({:mailbox_flush, _})` to accept both old and new message types**

During migration, messages might be old `%Message.User{}` or new `%UserMessage{}`. Add pattern matching for both, or update callers to use new types.

- [ ] **Step 8: Remove old `stream_event/3` function**

Delete the old function that called `Decoder.decode_event/2`.

- [ ] **Step 9: Run tests — expect failures**

Run: `mix test test/skill_kit/agent/server_test.exs --trace`
Expected: Failures because tests send tuples and expect tuples back. These will be fixed in the migration task.

Run: `mix compile --warnings-as-errors`
Expected: May have warnings about unused Decoder import — remove it.

- [ ] **Step 10: Commit**

```bash
git add lib/skill_kit/agent/server.ex
git commit -m "refactor: replace Decoder with SkillKit event pattern matching in Server"
```

---

### Task 7: Update Public API + Test Helpers

**Files:**
- Modify: `lib/skill_kit.ex`
- Modify: `lib/skill_kit/test.ex`

- [ ] **Step 1: Update `send_message_sync/3`**

Current `await_response/2` matches on tuples. Update to match on structs:

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

- [ ] **Step 2: Update `send_message/2` to create `UserMessage`**

Change `%Message.User{content: content}` to `%SkillKit.Types.UserMessage{content: content}`.

- [ ] **Step 3: Update test helpers to return SkillKit events**

In `lib/skill_kit/test.ex`, `expect_response/1` currently calls `Anthropic.Test.to_stream(response)`. Change to build SkillKit events directly:

```elixir
def expect_response(%SkillKit.Response.Text{content: text}) do
  events = [
    %SkillKit.Event.Delta{text: text},
    %SkillKit.Event.Done{stop_reason: :end_turn}
  ]

  Mox.expect(SkillKit.LLM.Mock, :stream, 1, fn _messages, _opts ->
    {:ok, Stream.map(events, & &1)}
  end)

  :ok
end

def expect_response(%SkillKit.Response.ToolCall{name: name, input: input}) do
  events = [
    %SkillKit.Event.ToolCallStart{id: "tc_test_#{:erlang.unique_integer([:positive])}", name: name},
    %SkillKit.Event.ToolCallComplete{id: "tc_test_#{:erlang.unique_integer([:positive])}", name: name, input: input},
    %SkillKit.Event.Done{stop_reason: :tool_use}
  ]

  Mox.expect(SkillKit.LLM.Mock, :stream, 1, fn _messages, _opts ->
    {:ok, Stream.map(events, & &1)}
  end)

  :ok
end

def expect_response(%SkillKit.Response.Error{status: status, message: message}) do
  Mox.expect(SkillKit.LLM.Mock, :stream, 1, fn _messages, _opts ->
    {:error, {status, message}}
  end)

  :ok
end
```

Note: `ToolCallStart` and `ToolCallComplete` need the same `id`. Extract to a variable:

```elixir
def expect_response(%SkillKit.Response.ToolCall{name: name, input: input}) do
  id = "tc_test_#{:erlang.unique_integer([:positive])}"

  events = [
    %SkillKit.Event.ToolCallStart{id: id, name: name},
    %SkillKit.Event.ToolCallComplete{id: id, name: name, input: input},
    %SkillKit.Event.Done{stop_reason: :tool_use}
  ]

  Mox.expect(SkillKit.LLM.Mock, :stream, 1, fn _messages, _opts ->
    {:ok, Stream.map(events, & &1)}
  end)

  :ok
end
```

Update `assert_response/2` and `expect_responses/1` similarly — they call through to the same `to_stream` logic. Factor out a private `build_event_stream/1` that converts a response type to a list of SkillKit events, then all three helpers use it.

- [ ] **Step 4: Commit**

```bash
git add lib/skill_kit.ex lib/skill_kit/test.ex
git commit -m "refactor: update public API and test helpers for struct-based events"
```

---

### Task 8: Migrate All Tests

**Files:**
- Modify: `test/skill_kit_test.exs`
- Modify: `test/skill_kit/test_test.exs`
- Modify: `test/skill_kit/agent/server_test.exs`
- Modify: `test/skill_kit/llm/anthropic/encoder_test.exs`
- Modify: `test/anthropic/test_test.exs`
- Modify: `test/anthropic/anthropic_test.exs`
- Modify: `test/skill_kit/conversation/store/filesystem_test.exs`
- Modify: `test/skill_kit/agent/agent_test.exs`
- Modify: `test/skill_kit/agent/core_test.exs`
- Modify: `lib/skill_kit/conversation/store.ex` — update `@type message` reference
- Modify: `lib/skill_kit/llm/llm.ex` — update `@type message` reference

This is the largest migration task. Work through each test file:

- [ ] **Step 1: Migrate `server_test.exs`**

Update all `assert_receive` patterns from tuples to structs:
- `{:skill_kit, ^agent_name, {:delta, text}}` → `%SkillKit.Event.Delta{agent: ^agent_name, text: text}`
- `{:skill_kit, ^agent_name, {:response, text}}` → `%SkillKit.Types.AssistantMessage{agent: ^agent_name, content: text}`
- `{:skill_kit, ^agent_name, {:error, reason}}` → `%SkillKit.Event.Error{agent: ^agent_name, reason: reason}`

Update `%Message.User{}` → `%SkillKit.Types.UserMessage{}`, `%Message.Assistant{}` → `%SkillKit.Types.AssistantMessage{}`, `%Message.System{}` → `%SkillKit.Types.SystemMessage{}` in assertions and message construction.

The shared `setup` block creates `%Definition{}` — this doesn't change.

- [ ] **Step 2: Migrate `skill_kit_test.exs`**

Same pattern — update `assert_receive` and message references. `send_message_sync` now returns `{:ok, %AssistantMessage{}}` instead of `{:ok, text}`.

- [ ] **Step 3: Migrate `test_test.exs`**

Update tests to verify SkillKit events come from mock (not Anthropic SSE events). The `expect_response` tests should verify the mock returns a stream of `%Event.Delta{}` and `%Event.Done{}`.

- [ ] **Step 4: Migrate encoder tests**

Update `encoder_test.exs` to use `%SkillKit.Types.*` structs instead of `%Message.*`.

- [ ] **Step 5: Migrate all remaining test files**

Search for `Message.User`, `Message.Assistant`, `Message.System`, `Message.ToolResult`, `Message.ToolCall` across all test files and update.

Run: `grep -rn "Message\.\(User\|Assistant\|System\|ToolResult\|ToolCall\)" test/`

Fix each reference.

- [ ] **Step 6: Run full test suite**

Run: `mix test`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add test/
git commit -m "refactor: migrate all tests to SkillKit.Types and struct-based events"
```

---

### Task 9: Delete Old Code + Final Cleanup

**Files:**
- Delete: `lib/skill_kit/llm/anthropic/decoder.ex`
- Delete: `lib/skill_kit/llm/message.ex`
- Delete: `test/skill_kit/llm/anthropic/decoder_test.exs`
- Delete: `test/skill_kit/llm/message_test.exs`
- Modify: `lib/anthropic/test.ex` — remove `to_stream/1` (no longer needed)
- Delete: `test/anthropic/to_stream_test.exs`
- Delete: `lib/skill_kit/response/respondable.ex` (already deleted, verify)

- [ ] **Step 1: Delete old Decoder and Message modules**

```bash
rm lib/skill_kit/llm/anthropic/decoder.ex
rm lib/skill_kit/llm/message.ex
rm test/skill_kit/llm/anthropic/decoder_test.exs
rm test/skill_kit/llm/message_test.exs
```

- [ ] **Step 2: Remove `to_stream/1` from `Anthropic.Test`**

Read `lib/anthropic/test.ex` and remove the `to_stream/1` function clauses and their aliases. Keep `text_events/1` and `tool_call_events/2` — they're used for Anthropic-level testing.

- [ ] **Step 3: Delete `to_stream_test.exs`**

```bash
rm test/anthropic/to_stream_test.exs
```

- [ ] **Step 4: Verify no references to deleted modules remain**

Run: `grep -rn "Decoder\." lib/ test/`
Run: `grep -rn "SkillKit.LLM.Message" lib/ test/`
Run: `grep -rn "Message\.User\|Message\.Assistant\|Message\.System\|Message\.ToolCall\b\|Message\.ToolResult" lib/ test/`

Expected: No matches (or only in comments/docs).

- [ ] **Step 5: Run full precommit pipeline**

Run: `mix precommit`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: delete Decoder, old Message types, and to_stream — replaced by Events and Types"
```

---

### Task 10: Update Demo/Chat Tasks + Documentation

**Files:**
- Modify: `lib/mix/tasks/skill_kit.demo.ex`
- Modify: `lib/mix/tasks/skill_kit.chat.ex`

- [ ] **Step 1: Update demo task**

The demo task receives `{:skill_kit, name, {:delta, text}}` etc. Update to match on structs:
- `%SkillKit.Event.Delta{text: text}` → `IO.write(text)`
- `%SkillKit.Types.AssistantMessage{content: text}` → completion
- `%SkillKit.Event.Error{reason: reason}` → error handling

- [ ] **Step 2: Update chat task**

Same pattern. Also update `%SkillKit.Event.ToolCallComplete{}` and `%SkillKit.Types.ToolResult{}` handling for the tool call display.

- [ ] **Step 3: Run full precommit pipeline**

Run: `mix precommit`
Expected: All steps pass

- [ ] **Step 4: Verify no old tuple patterns remain**

Run: `grep -rn "skill_kit.*delta\|skill_kit.*response\|skill_kit.*error\|skill_kit.*tool_call\|skill_kit.*tool_result" lib/ test/ --include="*.ex" --include="*.exs" | grep -v "skill_kit_" | grep ":skill_kit"`

Expected: No matches for old `{:skill_kit, name, {:event, ...}}` tuple patterns.

- [ ] **Step 5: Commit**

```bash
git add lib/mix/tasks/
git commit -m "refactor: update demo and chat tasks for struct-based events"
```
