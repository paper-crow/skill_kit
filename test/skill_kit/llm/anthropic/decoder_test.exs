defmodule SkillKit.LLM.Anthropic.DecoderTest do
  use ExUnit.Case, async: true

  alias SkillKit.LLM.Message
  alias SkillKit.LLM.Anthropic.Decoder

  describe "decode_events/1" do
    test "decodes a text-only response" do
      events = [
        %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}},
        %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
        %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hello"}},
        %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => " world"}},
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
        %{"type" => "message_stop"}
      ]

      assert %Message.Assistant{content: "Hello world", tool_calls: []} = Decoder.decode_events(events)
    end

    test "decodes a tool-use response" do
      events = [
        %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}},
        %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "tool_use", "id" => "tc_1", "name" => "build:check", "input" => %{}}},
        %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"project\""}},
        %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "input_json_delta", "partial_json" => ": \"a\"}"}},
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
        %{"type" => "message_stop"}
      ]

      assert %Message.Assistant{content: nil, tool_calls: [tc]} = Decoder.decode_events(events)
      assert %Message.ToolCall{id: "tc_1", name: "build:check", input: %{"project" => "a"}} = tc
    end

    test "decodes mixed text and tool use" do
      events = [
        %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}},
        %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
        %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Checking."}},
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "content_block_start", "index" => 1, "content_block" => %{"type" => "tool_use", "id" => "tc_1", "name" => "check", "input" => %{}}},
        %{"type" => "content_block_delta", "index" => 1, "delta" => %{"type" => "input_json_delta", "partial_json" => "{}"}},
        %{"type" => "content_block_stop", "index" => 1},
        %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
        %{"type" => "message_stop"}
      ]

      assert %Message.Assistant{content: "Checking.", tool_calls: [tc]} = Decoder.decode_events(events)
      assert tc.id == "tc_1"
    end

    test "decodes multiple tool calls" do
      events = [
        %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}},
        %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "tool_use", "id" => "tc_1", "name" => "read", "input" => %{}}},
        %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "input_json_delta", "partial_json" => "{}"}},
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "content_block_start", "index" => 1, "content_block" => %{"type" => "tool_use", "id" => "tc_2", "name" => "write", "input" => %{}}},
        %{"type" => "content_block_delta", "index" => 1, "delta" => %{"type" => "input_json_delta", "partial_json" => "{}"}},
        %{"type" => "content_block_stop", "index" => 1},
        %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
        %{"type" => "message_stop"}
      ]

      assert %Message.Assistant{tool_calls: [tc1, tc2]} = Decoder.decode_events(events)
      assert tc1.id == "tc_1"
      assert tc2.id == "tc_2"
    end
  end
end
