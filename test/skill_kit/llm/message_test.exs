defmodule SkillKit.LLM.MessageTest do
  use ExUnit.Case, async: true

  alias SkillKit.LLM.Message

  describe "User" do
    test "creates with content" do
      msg = %Message.User{content: "hello"}
      assert msg.content == "hello"
    end
  end

  describe "Assistant" do
    test "creates with content and no tool calls" do
      msg = %Message.Assistant{content: "response"}
      assert msg.content == "response"
      assert msg.tool_calls == []
    end

    test "creates with content and tool calls" do
      tool_call = %Message.ToolCall{id: "tc_1", name: "build:check", input: %{"project" => "a"}}
      msg = %Message.Assistant{content: "checking...", tool_calls: [tool_call]}
      assert length(msg.tool_calls) == 1
      assert hd(msg.tool_calls).name == "build:check"
    end
  end

  describe "ToolCall" do
    test "creates with id, name, and input" do
      tc = %Message.ToolCall{id: "tc_1", name: "files:read", input: %{"path" => "/tmp"}}
      assert tc.id == "tc_1"
      assert tc.name == "files:read"
      assert tc.input == %{"path" => "/tmp"}
    end
  end

  describe "ToolResult" do
    test "creates with tool_call_id and content" do
      tr = %Message.ToolResult{tool_call_id: "tc_1", content: "file contents"}
      assert tr.tool_call_id == "tc_1"
      assert tr.content == "file contents"
      assert tr.is_error == false
    end

    test "creates with is_error flag" do
      tr = %Message.ToolResult{tool_call_id: "tc_1", content: "not found", is_error: true}
      assert tr.is_error == true
    end
  end

  describe "System" do
    test "creates with content" do
      msg = %Message.System{content: "[Background task complete]"}
      assert msg.content == "[Background task complete]"
    end
  end
end
