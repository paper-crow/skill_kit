defmodule SkillKit.LLM.Anthropic.EncoderTest do
  use ExUnit.Case, async: true

  alias SkillKit.LLM.Anthropic.Encoder
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.SystemMessage
  alias SkillKit.Types.ToolCall
  alias SkillKit.Types.ToolResult
  alias SkillKit.Types.UserMessage

  describe "encode_messages/1" do
    test "encodes a simple user message" do
      messages = [%UserMessage{content: "hello"}]
      assert [%{"role" => "user", "content" => "hello"}] = Encoder.encode_messages(messages)
    end

    test "encodes an assistant message with no tool calls" do
      messages = [%AssistantMessage{content: "hi there"}]

      assert [%{"role" => "assistant", "content" => "hi there"}] =
               Encoder.encode_messages(messages)
    end

    test "encodes an assistant message with tool calls" do
      messages = [
        %AssistantMessage{
          content: "Let me check.",
          tool_calls: [
            %ToolCall{id: "tc_1", name: "build:check", input: %{"project" => "a"}}
          ]
        }
      ]

      assert [%{"role" => "assistant", "content" => content_blocks}] =
               Encoder.encode_messages(messages)

      assert [
               %{"type" => "text", "text" => "Let me check."},
               %{
                 "type" => "tool_use",
                 "id" => "tc_1",
                 "name" => "build:check",
                 "input" => %{"project" => "a"}
               }
             ] = content_blocks
    end

    test "encodes an assistant message with tool calls but no text" do
      messages = [
        %AssistantMessage{
          content: nil,
          tool_calls: [
            %ToolCall{id: "tc_1", name: "build:check", input: %{}}
          ]
        }
      ]

      assert [%{"role" => "assistant", "content" => content_blocks}] =
               Encoder.encode_messages(messages)

      assert [%{"type" => "tool_use", "id" => "tc_1"}] = content_blocks
    end

    test "encodes tool results as user message with content blocks" do
      messages = [
        %ToolResult{tool_call_id: "tc_1", content: "build passing"},
        %ToolResult{tool_call_id: "tc_2", content: "deployed", is_error: false}
      ]

      assert [%{"role" => "user", "content" => content_blocks}] =
               Encoder.encode_messages(messages)

      assert [
               %{"type" => "tool_result", "tool_use_id" => "tc_1", "content" => "build passing"},
               %{"type" => "tool_result", "tool_use_id" => "tc_2", "content" => "deployed"}
             ] = content_blocks
    end

    test "encodes tool result with is_error flag" do
      messages = [
        %ToolResult{tool_call_id: "tc_1", content: "not found", is_error: true}
      ]

      assert [%{"role" => "user", "content" => [block]}] = Encoder.encode_messages(messages)
      assert block["is_error"] == true
    end

    test "encodes a user message whose content is a list of content blocks (text + image)" do
      blocks = [
        %{"type" => "text", "text" => "Analyze this."},
        %{
          "type" => "image",
          "source" => %{"type" => "base64", "media_type" => "image/webp", "data" => "AAAA"}
        }
      ]

      [encoded] = Encoder.encode_messages([%UserMessage{content: blocks}])

      assert encoded == %{"role" => "user", "content" => blocks}
    end

    test "encodes system message as user message" do
      messages = [%SystemMessage{content: "[Task complete]"}]

      assert [%{"role" => "user", "content" => "[Task complete]"}] =
               Encoder.encode_messages(messages)
    end

    test "encodes a full conversation" do
      messages = [
        %UserMessage{content: "Deploy"},
        %AssistantMessage{
          content: "Checking.",
          tool_calls: [
            %ToolCall{id: "tc_1", name: "build:check", input: %{}}
          ]
        },
        %ToolResult{tool_call_id: "tc_1", content: "ok"},
        %AssistantMessage{content: "Done."}
      ]

      encoded = Encoder.encode_messages(messages)
      assert length(encoded) == 4
      assert Enum.map(encoded, & &1["role"]) == ["user", "assistant", "user", "assistant"]
    end

    test "handles assistant with nil content followed by tool result in multi-loop conversation" do
      messages = [
        %UserMessage{content: "review this"},
        %AssistantMessage{
          content: "Let me check",
          tool_calls: [
            %ToolCall{id: "tc_1", name: "activate_skill", input: %{"name" => "review"}},
            %ToolCall{id: "tc_2", name: "bash", input: %{"command" => "cat file.ex"}}
          ]
        },
        %ToolResult{tool_call_id: "tc_1", content: "skill loaded"},
        %ToolResult{tool_call_id: "tc_2", content: "file contents"},
        %AssistantMessage{
          content: nil,
          tool_calls: [
            %ToolCall{id: "tc_3", name: "bash", input: %{"command" => "cat other.ex"}}
          ]
        },
        %ToolResult{tool_call_id: "tc_3", content: "other contents"}
      ]

      encoded = Encoder.encode_messages(messages)
      assert length(encoded) == 5
      roles = Enum.map(encoded, & &1["role"])
      assert roles == ["user", "assistant", "user", "assistant", "user"]
    end
  end

  describe "encode_tools/1" do
    test "encodes tool definitions to Anthropic format" do
      tools = [
        %SkillKit.Tool{
          name: "bash",
          description: "Run a command",
          input_schema: %{
            "type" => "object",
            "properties" => %{"command" => %{"type" => "string"}}
          }
        }
      ]

      encoded = Encoder.encode_tools(tools)

      assert [%{"name" => "bash", "description" => "Run a command", "input_schema" => schema}] =
               encoded

      assert schema["properties"]["command"]
    end
  end

  describe "cache_control/1" do
    test "defaults to ephemeral with no ttl" do
      assert Encoder.cache_control("5m") == %{"type" => "ephemeral"}
    end

    test "adds the 1h ttl when requested" do
      assert Encoder.cache_control("1h") == %{"type" => "ephemeral", "ttl" => "1h"}
    end
  end

  describe "cache_system/2" do
    test "wraps a system string in a cached text block" do
      assert Encoder.cache_system("You are a bot.", "5m") == [
               %{
                 "type" => "text",
                 "text" => "You are a bot.",
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ]
    end

    test "passes nil through unchanged" do
      assert Encoder.cache_system(nil, "5m") == nil
    end
  end

  describe "cache_last_message/2" do
    test "tags the last block of the last message, leaving earlier messages untouched" do
      messages = [
        %{"role" => "user", "content" => "first"},
        %{"role" => "user", "content" => "last"}
      ]

      result = Encoder.cache_last_message(messages, "5m")

      assert List.first(result) == %{"role" => "user", "content" => "first"}

      assert List.last(result) == %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "last",
                   "cache_control" => %{"type" => "ephemeral"}
                 }
               ]
             }
    end

    test "tags the final block when content is already a block list" do
      messages = [
        %{
          "role" => "user",
          "content" => [%{"type" => "tool_result", "tool_use_id" => "x", "content" => "r"}]
        }
      ]

      [message] = Encoder.cache_last_message(messages, "5m")
      last_block = List.last(message["content"])
      assert last_block["cache_control"] == %{"type" => "ephemeral"}
    end

    test "passes an empty list through unchanged" do
      assert Encoder.cache_last_message([], "5m") == []
    end
  end
end
