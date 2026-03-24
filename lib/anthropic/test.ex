defmodule Anthropic.Test do
  @moduledoc """
  Anthropic-specific test helpers.

  Provides SSE event builders that construct valid Anthropic streaming
  event sequences for use in tests, and `to_stream/1` which converts
  SkillKit response types into mock LLM streams.
  """

  alias SkillKit.Response.Error
  alias SkillKit.Response.Text
  alias SkillKit.Response.ToolCall

  @doc """
  Converts a SkillKit response type into what `SkillKit.LLM.stream/2` would return.
  """
  @spec to_stream(Text.t() | ToolCall.t() | Error.t()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def to_stream(%Text{content: content}) do
    {:ok, Stream.map(text_events(content), & &1)}
  end

  def to_stream(%ToolCall{name: name, input: input}) do
    {:ok, Stream.map(tool_call_events(name, input), & &1)}
  end

  def to_stream(%Error{status: status, message: message}) do
    {:error, {status, message}}
  end

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
end
