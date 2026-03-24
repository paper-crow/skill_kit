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
