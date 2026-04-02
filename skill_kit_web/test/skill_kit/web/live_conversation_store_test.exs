defmodule SkillKit.Web.LiveConversationStoreTest do
  use ExUnit.Case, async: true

  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.UserMessage
  alias SkillKit.Web.LiveConversationStore

  @tmp_dir Path.expand("../../tmp/live_store_test", __DIR__)

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    {:ok, dir: @tmp_dir}
  end

  describe "load/3" do
    test "sends {:conversation_loaded, messages} to caller on load", %{dir: dir} do
      messages = [
        %UserMessage{content: "hello"},
        %AssistantMessage{content: "hi", tool_calls: []}
      ]

      LiveConversationStore.save("test-conv", messages, dir: dir, caller: self())

      {:ok, loaded} = LiveConversationStore.load("test-conv", dir: dir, caller: self())

      assert length(loaded) == 2
      assert_receive {:conversation_loaded, ^loaded}
    end

    test "sends {:conversation_loaded, []} for empty conversation", %{dir: dir} do
      {:ok, []} = LiveConversationStore.load("nonexistent", dir: dir, caller: self())

      assert_receive {:conversation_loaded, []}
    end

    test "does not send if no caller in opts", %{dir: dir} do
      {:ok, []} = LiveConversationStore.load("nonexistent", dir: dir)

      refute_receive {:conversation_loaded, _}
    end
  end

  describe "save/3" do
    test "sends {:conversation_saved, messages} to caller on save", %{dir: dir} do
      messages = [%UserMessage{content: "hello"}]

      :ok = LiveConversationStore.save("test-conv", messages, dir: dir, caller: self())

      assert_receive {:conversation_saved, ^messages}
    end

    test "persists to filesystem", %{dir: dir} do
      messages = [%UserMessage{content: "persisted"}]
      :ok = LiveConversationStore.save("test-conv", messages, dir: dir, caller: self())

      {:ok, loaded} = LiveConversationStore.load("test-conv", dir: dir, caller: self())
      assert [%UserMessage{content: "persisted"}] = loaded
    end

    test "does not send if no caller in opts", %{dir: dir} do
      messages = [%UserMessage{content: "hello"}]
      :ok = LiveConversationStore.save("test-conv", messages, dir: dir)

      refute_receive {:conversation_saved, _}
    end
  end

  describe "delete/3" do
    test "deletes conversation and notifies caller", %{dir: dir} do
      messages = [%UserMessage{content: "hello"}]
      :ok = LiveConversationStore.save("test-conv", messages, dir: dir, caller: self())

      :ok = LiveConversationStore.delete("test-conv", dir: dir, caller: self())

      assert_receive {:conversation_deleted, "test-conv"}
      {:ok, []} = LiveConversationStore.load("test-conv", dir: dir, caller: self())
    end

    test "does not send if no caller in opts", %{dir: dir} do
      :ok = LiveConversationStore.delete("nonexistent", dir: dir)

      refute_receive {:conversation_deleted, _}
    end
  end
end
