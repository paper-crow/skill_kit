defmodule SkillKit.Conversation.Store.FilesystemTest do
  use ExUnit.Case, async: false

  alias SkillKit.Conversation.Store.Filesystem
  alias SkillKit.Storage
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.UserMessage

  setup do
    start_supervised!(Storage.Memory)
    {:ok, config: [path: "conversations"]}
  end

  test "save and load round-trips messages", %{config: config} do
    messages = [
      %UserMessage{content: "hello"},
      %AssistantMessage{content: "hi there", tool_calls: []}
    ]

    assert :ok = Filesystem.save("conv-1", messages, config)
    assert {:ok, loaded} = Filesystem.load("conv-1", config)
    assert loaded == messages
  end

  test "load returns empty list for nonexistent conversation", %{config: config} do
    assert {:ok, []} = Filesystem.load("nonexistent", config)
  end

  test "delete removes conversation file", %{config: config} do
    Filesystem.save("conv-2", [%UserMessage{content: "test"}], config)
    assert :ok = Filesystem.delete("conv-2", config)
    assert {:ok, []} = Filesystem.load("conv-2", config)
  end

  test "delete is idempotent for nonexistent conversation", %{config: config} do
    assert :ok = Filesystem.delete("nonexistent", config)
  end

  test "sanitizes conversation id for filesystem safety", %{config: config} do
    messages = [%UserMessage{content: "test"}]
    assert :ok = Filesystem.save("../../evil", messages, config)
    refute Storage.exists?("conversations/../../evil.bin")
    assert Storage.exists?("conversations/______evil.bin")
  end
end
