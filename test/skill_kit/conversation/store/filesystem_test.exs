defmodule SkillKit.Conversation.Store.FilesystemTest do
  use ExUnit.Case, async: true

  alias SkillKit.Conversation.Store.Filesystem
  alias SkillKit.LLM.Message

  @test_path Path.join(
               System.tmp_dir!(),
               "skill_kit_conv_test_#{:erlang.unique_integer([:positive])}"
             )

  setup do
    File.rm_rf!(@test_path)
    File.mkdir_p!(@test_path)
    on_exit(fn -> File.rm_rf!(@test_path) end)
    {:ok, config: [path: @test_path]}
  end

  test "save and load round-trips messages", %{config: config} do
    messages = [
      %Message.User{content: "hello"},
      %Message.Assistant{content: "hi there", tool_calls: []}
    ]

    assert :ok = Filesystem.save("conv-1", messages, config)
    assert {:ok, loaded} = Filesystem.load("conv-1", config)
    assert loaded == messages
  end

  test "load returns empty list for nonexistent conversation", %{config: config} do
    assert {:ok, []} = Filesystem.load("nonexistent", config)
  end

  test "delete removes conversation file", %{config: config} do
    Filesystem.save("conv-2", [%Message.User{content: "test"}], config)
    assert :ok = Filesystem.delete("conv-2", config)
    assert {:ok, []} = Filesystem.load("conv-2", config)
  end

  test "delete is idempotent for nonexistent conversation", %{config: config} do
    assert :ok = Filesystem.delete("nonexistent", config)
  end

  test "sanitizes conversation id for filesystem safety", %{config: config} do
    messages = [%Message.User{content: "test"}]
    assert :ok = Filesystem.save("../../evil", messages, config)
    # Should create a safe filename, not traverse directories
    refute File.exists?(Path.join([@test_path, "..", "..", "evil.bin"]))
  end
end
