defmodule SkillKit.Web.ConversationStoreTest do
  use ExUnit.Case, async: true

  alias SkillKit.Web.ConversationStore
  alias SkillKit.Types.UserMessage
  alias SkillKit.Types.AssistantMessage

  @tmp_dir "test/tmp/conversation_store_test"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    {:ok, store_dir: @tmp_dir}
  end

  test "save and load round-trips messages", %{store_dir: dir} do
    messages = [
      %UserMessage{content: "Hello"},
      %AssistantMessage{content: "Hi there!"}
    ]

    assert :ok = ConversationStore.save("conv-1", messages, dir: dir)
    assert {:ok, loaded} = ConversationStore.load("conv-1", dir: dir)
    assert length(loaded) == 2
    assert hd(loaded).content == "Hello"
  end

  test "load returns empty list for missing conversation", %{store_dir: dir} do
    assert {:ok, []} = ConversationStore.load("nonexistent", dir: dir)
  end

  test "save overwrites existing conversation", %{store_dir: dir} do
    messages1 = [%UserMessage{content: "First"}]
    messages2 = [%UserMessage{content: "First"}, %AssistantMessage{content: "Response"}]
    assert :ok = ConversationStore.save("conv-1", messages1, dir: dir)
    assert :ok = ConversationStore.save("conv-1", messages2, dir: dir)
    assert {:ok, loaded} = ConversationStore.load("conv-1", dir: dir)
    assert length(loaded) == 2
  end

  test "delete removes a conversation", %{store_dir: dir} do
    messages = [%UserMessage{content: "Hello"}]
    ConversationStore.save("conv-1", messages, dir: dir)
    assert :ok = ConversationStore.delete("conv-1", dir: dir)
    assert {:ok, []} = ConversationStore.load("conv-1", dir: dir)
  end

  test "delete nonexistent conversation returns :ok", %{store_dir: dir} do
    assert :ok = ConversationStore.delete("never-existed", dir: dir)
  end

  test "load returns error for corrupted JSON", %{store_dir: dir} do
    path = Path.join(dir, "corrupt.json")
    File.write!(path, "not valid json {{{")
    assert {:error, :corrupt} = ConversationStore.load("corrupt", dir: dir)
  end

  test "round-trips ToolResult and ToolCall messages", %{store_dir: dir} do
    alias SkillKit.Types.ToolCall
    alias SkillKit.Types.ToolResult

    messages = [
      %AssistantMessage{
        content: "Let me check.",
        tool_calls: [%ToolCall{id: "tc_1", name: "docs:read", input: %{"path" => "a.md"}}]
      },
      %ToolResult{tool_call_id: "tc_1", content: "# Hello", name: "docs:read", is_error: false}
    ]

    assert :ok = ConversationStore.save("conv-tools", messages, dir: dir)
    assert {:ok, loaded} = ConversationStore.load("conv-tools", dir: dir)
    assert length(loaded) == 2

    [assistant, tool_result] = loaded
    assert assistant.content == "Let me check."
    assert length(assistant.tool_calls) == 1
    assert hd(assistant.tool_calls).name == "docs:read"
    assert tool_result.tool_call_id == "tc_1"
    assert tool_result.is_error == false
  end

  test "sanitizes special characters in conversation_id", %{store_dir: dir} do
    messages = [%UserMessage{content: "test"}]
    assert :ok = ConversationStore.save("../attack", messages, dir: dir)

    # The file should be saved with sanitized name, not allowing path traversal
    refute File.exists?(Path.join(Path.dirname(dir), "attack.json"))
    assert {:ok, [msg]} = ConversationStore.load("../attack", dir: dir)
    assert msg.content == "test"
  end
end
