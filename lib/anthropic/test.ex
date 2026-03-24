defmodule Anthropic.Test do
  @moduledoc """
  Anthropic-specific test helpers.

  Provides SSE event builders that construct valid Anthropic streaming
  event sequences for use in tests.
  """

  @doc """
  Builds a complete Anthropic SSE event sequence for a text response.

  Returns a list of 6 event maps representing a streamed text reply.
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

  Returns a list of 6 event maps representing a streamed tool call
  with the given `name` and `input`.
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
