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
      raw = %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_1",
          "role" => "assistant",
          "content" => [],
          "usage" => %{"input_tokens" => 42}
        }
      }

      assert %MessageStart{id: "msg_1", usage: %{"input_tokens" => 42}} = Event.parse(raw)
    end

    test "parses content_block_start for text" do
      raw = %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }

      assert %ContentBlockStart{index: 0, content_block: %{type: :text}} = Event.parse(raw)
    end

    test "parses content_block_start for tool_use" do
      raw = %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => "tc_1", "name" => "echo"}
      }

      assert %ContentBlockStart{
               index: 0,
               content_block: %{type: :tool_use, id: "tc_1", name: "echo"}
             } =
               Event.parse(raw)
    end

    test "parses content_block_delta with text_delta" do
      raw = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "Hi"}
      }

      assert %ContentBlockDelta{index: 0, delta: %{type: :text_delta, text: "Hi"}} =
               Event.parse(raw)
    end

    test "parses content_block_delta with input_json_delta" do
      raw = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"cmd\":"}
      }

      assert %ContentBlockDelta{
               index: 0,
               delta: %{type: :input_json_delta, partial_json: "{\"cmd\":"}
             } =
               Event.parse(raw)
    end

    test "parses content_block_stop" do
      raw = %{"type" => "content_block_stop", "index" => 0}
      assert %ContentBlockStop{index: 0} = Event.parse(raw)
    end

    test "parses message_delta" do
      raw = %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 10}
      }

      assert %MessageDelta{stop_reason: :end_turn, usage: %{"output_tokens" => 10}} =
               Event.parse(raw)
    end

    test "parses message_stop" do
      raw = %{"type" => "message_stop"}
      assert %MessageStop{} = Event.parse(raw)
    end

    test "returns :skip for unknown events" do
      assert :skip = Event.parse(%{"type" => "ping"})
      assert :skip = Event.parse(%{"type" => "unknown_thing"})
    end

    test "message_start without usage" do
      raw = %{
        "type" => "message_start",
        "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
      }

      assert %MessageStart{id: "msg_1", usage: nil} = Event.parse(raw)
    end
  end
end
