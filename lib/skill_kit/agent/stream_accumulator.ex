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

  alias SkillKit.Event.Usage
  alias SkillKit.Types.AssistantMessage

  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          cache_creation_input_tokens: non_neg_integer(),
          cache_read_input_tokens: non_neg_integer()
        }

  @type t :: %{
          text: String.t(),
          tool_calls: [SkillKit.Types.ToolCall.t()],
          usage: usage()
        }

  @spec new() :: t()
  def new do
    %{text: "", tool_calls: [], usage: empty_usage()}
  end

  @doc "An all-zero usage map."
  @spec empty_usage() :: usage()
  def empty_usage do
    %{
      input_tokens: 0,
      output_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0
    }
  end

  @doc "Sums a `%Usage{}` event into a running usage map."
  @spec merge_usage(usage(), Usage.t()) :: usage()
  def merge_usage(acc_usage, %Usage{} = usage) do
    %{
      input_tokens: acc_usage.input_tokens + usage.input_tokens,
      output_tokens: acc_usage.output_tokens + usage.output_tokens,
      cache_creation_input_tokens:
        acc_usage.cache_creation_input_tokens + usage.cache_creation_input_tokens,
      cache_read_input_tokens: acc_usage.cache_read_input_tokens + usage.cache_read_input_tokens
    }
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
