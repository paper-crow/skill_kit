defmodule SkillKit.Conversation.Store.MemoryTest do
  use ExUnit.Case, async: true

  alias SkillKit.Conversation.Store.Memory
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.UserMessage

  setup do
    {:ok, pid} = Memory.start_link()
    {:ok, config: [pid: pid]}
  end

  test "save and load round-trips messages", %{config: config} do
    messages = [
      %UserMessage{content: "hello"},
      %AssistantMessage{content: "hi there", tool_calls: []}
    ]

    assert :ok = Memory.save("conv-1", messages, config)
    assert {:ok, ^messages} = Memory.load("conv-1", config)
  end

  test "load returns empty list for nonexistent conversation", %{config: config} do
    assert {:ok, []} = Memory.load("nonexistent", config)
  end

  test "delete removes conversation", %{config: config} do
    Memory.save("conv-2", [%UserMessage{content: "test"}], config)
    assert :ok = Memory.delete("conv-2", config)
    assert {:ok, []} = Memory.load("conv-2", config)
  end

  test "delete is idempotent for nonexistent conversation", %{config: config} do
    assert :ok = Memory.delete("nonexistent", config)
  end

  test "overwrite replaces previous messages", %{config: config} do
    Memory.save("conv-3", [%UserMessage{content: "first"}], config)
    Memory.save("conv-3", [%UserMessage{content: "second"}], config)

    assert {:ok, [%UserMessage{content: "second"}]} = Memory.load("conv-3", config)
  end

  test "notifies caller on save when notify option is set", %{config: config} do
    config = Keyword.put(config, :notify, self())
    messages = [%UserMessage{content: "hello"}]

    Memory.save("conv-1", messages, config)

    assert_receive {:memory_store, :save, "conv-1", ^messages}
  end

  test "does not send notification when notify is not set", %{config: config} do
    Memory.save("conv-1", [%UserMessage{content: "hello"}], config)

    refute_receive {:memory_store, :save, _, _}
  end
end
