defmodule Anthropic.TestTest do
  use ExUnit.Case, async: true

  alias SkillKit.LLM.Anthropic.Decoder
  alias SkillKit.LLM.Message

  describe "text_events/1" do
    test "produces events that decode to a text Assistant message" do
      events = Anthropic.Test.text_events("Hello world")
      result = Decoder.decode_events(events)

      assert %Message.Assistant{content: "Hello world", tool_calls: []} = result
    end

    test "returns a list of 6 SSE event maps" do
      events = Anthropic.Test.text_events("Hi")

      assert length(events) == 6
      assert %{"type" => "message_start"} = List.first(events)
      assert %{"type" => "message_stop"} = List.last(events)
    end
  end

  describe "tool_call_events/2" do
    test "produces events that decode to a tool call Assistant message" do
      events = Anthropic.Test.tool_call_events("echo", %{"command" => "echo hi"})
      result = Decoder.decode_events(events)

      assert %Message.Assistant{content: nil, tool_calls: [tool_call]} = result
      assert tool_call.name == "echo"
      assert tool_call.input == %{"command" => "echo hi"}
    end

    test "returns a list of 6 SSE event maps" do
      events = Anthropic.Test.tool_call_events("bash", %{"cmd" => "ls"})

      assert length(events) == 6
      assert %{"type" => "message_start"} = List.first(events)
      assert %{"type" => "message_stop"} = List.last(events)
    end
  end
end
