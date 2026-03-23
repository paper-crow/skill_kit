defmodule SkillKit.LLMTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  describe "stream/2" do
    test "dispatches to the configured provider" do
      Application.put_env(:skill_kit, SkillKit.LLM, {SkillKit.LLM.Mock, [api_key: "sk-test"]})

      on_exit(fn -> Application.delete_env(:skill_kit, SkillKit.LLM) end)

      expect(SkillKit.LLM.Mock, :stream, fn config, messages, opts ->
        assert config == [api_key: "sk-test"]
        assert messages == [%{"role" => "user", "content" => "Hi"}]
        assert opts == [model: "claude-sonnet-4-20250514"]
        {:ok, Stream.map([], & &1)}
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:ok, _stream} = SkillKit.LLM.stream(messages, model: "claude-sonnet-4-20250514")
    end

    test "allows provider override via opts" do
      expect(SkillKit.LLM.Mock, :stream, fn _config, _messages, _opts ->
        {:ok, Stream.map([], & &1)}
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:ok, _} = SkillKit.LLM.stream(messages, provider: {SkillKit.LLM.Mock, []})
    end

    test "falls back to default when no config set" do
      Application.delete_env(:skill_kit, SkillKit.LLM)

      assert {:ok, {mod, _config}} = SkillKit.LLM.default_provider()
      assert mod == SkillKit.LLM.Anthropic
    end
  end
end
