# Adding an LLM Provider

This guide walks through adding a new LLM provider adapter to SkillKit.

## Architecture overview

The integration has three layers:

```
Provider API  →  provider event structs  →  Streamable protocol  →  SkillKit events
```

The **provider** (e.g., the `anthropic` hex package) knows nothing about SkillKit.
It produces its own typed event structs (`MyProvider.Event.*`).

**SkillKit** owns the conversion. `SkillKit.Event.Streamable` implementations live in
the SkillKit codebase and translate provider events into the universal `SkillKit.Event.*`
structs that the rest of the system consumes.

The **adapter** (`SkillKit.LLM.MyProvider`) is the thin glue: it calls the provider's
API, encodes SkillKit message types into the provider's wire format, and wires the
resulting stream through `Streamable`.

## Required output events

Every provider stream must yield these structs (all in the `SkillKit.Event` namespace):

| Struct | Required fields | When to emit |
|---|---|---|
| `Delta` | `text` | Each text fragment from the LLM |
| `ToolCallStart` | `id`, `name` | When a tool call begins (name and id known) |
| `ToolCallComplete` | `id`, `name`, `input` | When a tool call's full input is parsed |
| `Usage` | `input_tokens`, `output_tokens` | Token counts (may arrive in two separate events) |
| `Done` | `stop_reason` | Turn complete; `:end_turn` or `:tool_use` |

## Step-by-step implementation

### 1. Define provider event structs

Define typed structs in the provider's own namespace. These are usually provided
by the provider's hex package. If you are wrapping a raw HTTP stream, define them
yourself:

```elixir
defmodule MyProvider.Event.TextChunk do
  defstruct [:text]
end

defmodule MyProvider.Event.ToolStart do
  defstruct [:id, :name]
end

defmodule MyProvider.Event.ToolDone do
  defstruct [:id, :name, :input_json]
end

defmodule MyProvider.Event.StreamEnd do
  defstruct [:reason, :input_tokens, :output_tokens]
end
```

### 2. Implement `Streamable` for each event type

Create `lib/skill_kit/event/streamable/my_provider.ex`. Implement one clause per
provider event type. Return `{events, updated_acc}` — an empty list when the event
carries no output-worthy signal yet.

```elixir
defimpl SkillKit.Event.Streamable, for: MyProvider.Event.TextChunk do
  alias SkillKit.Event.Delta

  def to_events(%{text: text}, acc) do
    {[%Delta{text: text}], acc}
  end
end

defimpl SkillKit.Event.Streamable, for: MyProvider.Event.ToolStart do
  alias SkillKit.Event.ToolCallStart

  def to_events(%{id: id, name: name}, acc) do
    {[%ToolCallStart{id: id, name: name}], acc}
  end
end

defimpl SkillKit.Event.Streamable, for: MyProvider.Event.ToolDone do
  alias SkillKit.Event.ToolCallComplete

  def to_events(%{id: id, name: name, input_json: json}, acc) do
    input = Jason.decode!(json)
    {[%ToolCallComplete{id: id, name: name, input: input}], acc}
  end
end

defimpl SkillKit.Event.Streamable, for: MyProvider.Event.StreamEnd do
  alias SkillKit.Event.Done
  alias SkillKit.Event.Usage

  def to_events(%{reason: reason, input_tokens: i, output_tokens: o}, acc) do
    events = [
      %Usage{input_tokens: i, output_tokens: o},
      %Done{stop_reason: reason}
    ]

    {events, acc}
  end
end
```

When a provider splits partial state across multiple events (e.g., JSON for a tool
call arrives in fragments), use the accumulator:

```elixir
defimpl SkillKit.Event.Streamable, for: MyProvider.Event.JsonFragment do
  def to_events(%{id: id, partial: json}, acc) do
    acc = Map.update(acc, :partial_json, %{id => json}, fn pj ->
      Map.update(pj, id, json, &(&1 <> json))
    end)

    {[], acc}
  end
end
```

Then a later `ToolDone` event reads `acc.partial_json[id]` to assemble the final input.

### 3. Write the adapter

Create `lib/skill_kit/llm/my_provider.ex`:

```elixir
defmodule SkillKit.LLM.MyProvider do
  @behaviour SkillKit.LLM

  alias SkillKit.Event.Streamable
  alias SkillKit.LLM.MyProvider.Encoder

  @default_model "my-model-latest"
  @default_max_tokens 4096

  @impl true
  def stream(messages, opts) do
    api_key = Keyword.get(opts, :api_key) || resolve_api_key()
    encoded = Encoder.encode_messages(messages)

    request_opts =
      opts
      |> Keyword.drop([:api_key])
      |> Keyword.put_new(:model, @default_model)
      |> Keyword.put_new(:max_tokens, @default_max_tokens)

    case MyProvider.stream([api_key: api_key], encoded, request_opts) do
      {:ok, raw_stream} -> {:ok, to_skill_kit_stream(raw_stream)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp to_skill_kit_stream(raw_stream) do
    Stream.transform(raw_stream, %{}, &Streamable.to_events/2)
  end

  defp resolve_api_key do
    config = Application.get_env(:skill_kit, __MODULE__, [])
    Keyword.get(config, :api_key) || System.get_env("MY_PROVIDER_API_KEY")
  end
end
```

The initial accumulator passed to `Stream.transform/3` should be a plain map with
whatever keys your `Streamable` implementations expect. For a provider that needs
block-tracking and JSON accumulation, use `%{blocks: %{}, partial_json: %{}}`.

### 4. Register the provider in config

```elixir
# config/config.exs
config :skill_kit, SkillKit.LLM,
  providers: [
    anthropic: SkillKit.LLM.Anthropic,
    my_provider: SkillKit.LLM.MyProvider
  ],
  default_provider: :anthropic

config :skill_kit, SkillKit.LLM.MyProvider,
  api_key: System.get_env("MY_PROVIDER_API_KEY")
```

Once registered, the provider is addressable via model URI strings:

```elixir
SkillKit.LLM.stream(messages, model: "my_provider://my-model-latest?max_tokens=4096")
```

## Message encoding

`SkillKit.LLM.stream/2` passes `SkillKit.Types.*` message structs to the adapter.
The adapter's encoder translates them to the provider's wire format.

| SkillKit type | Typical wire shape |
|---|---|
| `UserMessage{content: text}` | `%{"role" => "user", "content" => text}` |
| `AssistantMessage{content: text, tool_calls: []}` | `%{"role" => "assistant", "content" => text}` |
| `AssistantMessage{content: nil, tool_calls: calls}` | assistant message with tool-use content blocks |
| `SystemMessage{content: text}` | provider-dependent (often a top-level `:system` param) |
| `ToolResult{tool_call_id: id, content: text}` | provider-dependent tool result format |

Some providers (including Anthropic) require consecutive `ToolResult` messages to be
grouped into a single request message. Handle this in the encoder by chunking the
message list before mapping.

`ToolCall` structs inside `AssistantMessage.tool_calls` carry `id`, `name`, and `input`
(a decoded map). Re-encode `input` as a map for the provider's request body.

## Reference implementation

The Anthropic adapter is the canonical example:

- `lib/skill_kit/llm/anthropic/anthropic.ex` — adapter
- `lib/skill_kit/llm/anthropic/encoder.ex` — message encoder
- `lib/skill_kit/event/streamable/anthropic.ex` — Streamable implementations

See `SkillKit.Event.Streamable` and `SkillKit.LLM` for the behaviour and protocol
specifications.
