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
end
