defmodule Anthropic.ToStreamTest do
  use ExUnit.Case, async: true

  alias SkillKit.LLM.Anthropic.Decoder
  alias SkillKit.LLM.Message
  alias SkillKit.Response.Error
  alias SkillKit.Response.Text
  alias SkillKit.Response.ToolCall

  describe "to_stream/1" do
    test "Text returns stream that decodes to text message" do
      {:ok, stream} = Anthropic.Test.to_stream(%Text{content: "Hello"})
      events = Enum.to_list(stream)

      assert %Message.Assistant{content: "Hello", tool_calls: []} =
               Decoder.decode_events(events)
    end

    test "ToolCall returns stream that decodes to tool call message" do
      {:ok, stream} = Anthropic.Test.to_stream(%ToolCall{name: "bash", input: %{"cmd" => "ls"}})
      events = Enum.to_list(stream)
      result = Decoder.decode_events(events)

      assert %Message.Assistant{tool_calls: [tc]} = result
      assert tc.name == "bash"
      assert tc.input == %{"cmd" => "ls"}
    end

    test "Error returns error tuple" do
      assert {:error, {500, "boom"}} =
               Anthropic.Test.to_stream(%Error{status: 500, message: "boom"})
    end
  end
end
