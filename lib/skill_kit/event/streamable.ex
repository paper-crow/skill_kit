defprotocol SkillKit.Event.Streamable do
  @moduledoc """
  Converts provider-specific events into SkillKit events.

  Each provider has its own typed event structs (e.g., `Anthropic.Event.ContentBlockDelta`).
  SkillKit defines `Streamable` implementations for those types, bridging the
  provider boundary. The provider itself knows nothing about SkillKit.

  ## How it works

  `stream/2` takes a single provider event and an accumulator map, returning
  `{events, updated_acc}` where `events` is a list of zero or more `SkillKit.Event.*`
  structs.

    * **Zero events** — the provider event is intermediate state (e.g., a partial
      JSON fragment for a tool call input). The accumulator stores it.
    * **One event** — direct mapping (e.g., text delta → `%Delta{}`).
    * **Multiple events** — the provider event carries multiple signals
      (e.g., `MessageDelta` yields both `%Usage{}` and `%Done{}`).

  ## Implementing for a new provider

  1. Define typed event structs in your provider's namespace:

          defmodule MyProvider.Event.TextChunk do
            defstruct [:text]
          end

          defmodule MyProvider.Event.Done do
            defstruct [:reason]
          end

  2. Implement `Streamable` for each event type in SkillKit's codebase
     (not in the provider — SkillKit owns the conversion):

          defimpl SkillKit.Event.Streamable, for: MyProvider.Event.TextChunk do
            def stream(%{text: text}, acc) do
              {[%SkillKit.Event.Delta{text: text}], acc}
            end
          end

          defimpl SkillKit.Event.Streamable, for: MyProvider.Event.Done do
            def stream(%{reason: reason}, acc) do
              {[%SkillKit.Event.Done{stop_reason: reason}], acc}
            end
          end

  3. Wire the stream in your LLM adapter using `Stream.transform/3`:

          Stream.transform(provider_stream, %{}, &Streamable.stream/2)

  ## Accumulator

  The accumulator is a plain map. Common patterns:

    * `:blocks` — tracks content block metadata by index (needed when a
      `content_block_stop` must know whether the block was text or tool_use)
    * `:partial_json` — accumulates JSON fragments by block index for tool
      call inputs that arrive across multiple delta events

  See `SkillKit.LLM.Anthropic` and the `Anthropic.Event` types for a
  complete reference implementation.
  """

  @spec stream(t(), map()) :: {[struct()], map()}
  def stream(event, acc)
end
