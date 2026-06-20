defmodule SkillKit.LLMTest do
  use ExUnit.Case, async: true

  import Mox

  setup :verify_on_exit!

  describe "stream/2" do
    test "dispatches to the configured default provider" do
      expect(SkillKit.LLM.Mock, :stream, fn messages, _opts ->
        assert messages == [%{"role" => "user", "content" => "Hi"}]
        {:ok, Stream.map([], & &1)}
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:ok, _stream} = SkillKit.LLM.stream(messages)
    end

    test "resolves provider from model URI" do
      expect(SkillKit.LLM.Mock, :stream, fn messages, opts ->
        assert messages == [%{"role" => "user", "content" => "Hi"}]
        assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"
        {:ok, Stream.map([], & &1)}
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]

      assert {:ok, _stream} =
               SkillKit.LLM.stream(messages, model: "mock://claude-sonnet-4-20250514")
    end

    test "bare model string uses default provider" do
      expect(SkillKit.LLM.Mock, :stream, fn _messages, opts ->
        assert Keyword.get(opts, :model) == "claude-sonnet-4-20250514"
        {:ok, Stream.map([], & &1)}
      end)

      messages = [%{"role" => "user", "content" => "Hi"}]
      assert {:ok, _} = SkillKit.LLM.stream(messages, model: "claude-sonnet-4-20250514")
    end

    test "returns error for unknown provider" do
      messages = [%{"role" => "user", "content" => "Hi"}]

      assert {:error, {:unknown_provider, "bogus"}} =
               SkillKit.LLM.stream(messages, model: "bogus://model")
    end
  end

  describe "get_provider_and_opts/1 query params" do
    test "passes query params through to the provider as an opaque string map" do
      assert {:ok, SkillKit.LLM.Mock, opts} =
               SkillKit.LLM.get_provider_and_opts(
                 "mock://a-model?max_tokens=4096&temperature=0.7&custom=x"
               )

      assert opts[:model] == "a-model"
      assert opts[:params] == %{"max_tokens" => "4096", "temperature" => "0.7", "custom" => "x"}
    end

    test "omits :params when the model URI has no query string" do
      assert {:ok, SkillKit.LLM.Mock, opts} =
               SkillKit.LLM.get_provider_and_opts("mock://a-model")

      assert opts[:model] == "a-model"
      refute Keyword.has_key?(opts, :params)
    end
  end

  describe "get_provider/1" do
    test "finds configured provider by atom" do
      assert {:ok, SkillKit.LLM.Mock} = SkillKit.LLM.get_provider(:mock)
    end

    test "finds configured provider by string" do
      assert {:ok, SkillKit.LLM.Mock} = SkillKit.LLM.get_provider("mock")
    end

    test "returns error for unknown provider" do
      assert {:error, {:unknown_provider, :nope}} = SkillKit.LLM.get_provider(:nope)
    end
  end
end
