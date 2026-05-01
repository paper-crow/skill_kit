defmodule SkillKit.Agent.StreamAccumulator do
  @moduledoc """
  Shared helpers for consuming an LLM event stream into an
  `%AssistantMessage{}`.

  Used by `SkillKit.Agent.Server` for the main agent loop and by
  `SkillKit.Agent.SkillActivation` for the in-process skill sub-loop.

  The accumulator is a plain map holding partial text, the running list
  of tool calls, and accumulated usage. `new/0` builds an empty one and
  `finalize/1` turns it into an `%AssistantMessage{}`.

  Event-specific updates (text concatenation, tool-call collection,
  usage merging) are applied by the caller inside its own
  `Enum.reduce/3`, so each consumer can emit its own side effects
  (event notification, telemetry, agent tagging) without coupling to
  this module.
  """

  alias SkillKit.Types.AssistantMessage

  @type t :: %{
          text: String.t(),
          tool_calls: [SkillKit.Types.ToolCall.t()],
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}
        }

  @spec new() :: t()
  def new do
    %{text: "", tool_calls: [], usage: %{input_tokens: 0, output_tokens: 0}}
  end

  @doc "Finalizes the accumulator into an `%AssistantMessage{}`."
  @spec finalize(t()) :: AssistantMessage.t()
  def finalize(acc) do
    content = if acc.text == "", do: nil, else: acc.text

    %AssistantMessage{
      content: content,
      tool_calls: acc.tool_calls
    }
  end
end
