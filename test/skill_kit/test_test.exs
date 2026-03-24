defmodule SkillKit.TestTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.LLM.Anthropic.Decoder
  alias SkillKit.LLM.Message
  alias SkillKit.Response.Error
  alias SkillKit.Response.Text
  alias SkillKit.Response.ToolCall

  describe "expect_response/1" do
    setup :verify_on_exit!

    test "sets up Mox expectation for Text" do
      SkillKit.Test.expect_response(%Text{content: "Hello"})

      {:ok, stream} = SkillKit.LLM.Mock.stream([], [])
      events = Enum.to_list(stream)
      result = Decoder.decode_events(events)

      assert %Message.Assistant{content: "Hello"} = result
    end

    test "sets up Mox expectation for ToolCall" do
      SkillKit.Test.expect_response(%ToolCall{name: "bash", input: %{"cmd" => "ls"}})

      {:ok, stream} = SkillKit.LLM.Mock.stream([], [])
      events = Enum.to_list(stream)
      result = Decoder.decode_events(events)

      assert %Message.Assistant{tool_calls: [tc]} = result
      assert tc.name == "bash"
    end

    test "sets up Mox expectation for Error" do
      SkillKit.Test.expect_response(%Error{status: 429, message: "rate limited"})

      assert {:error, {429, "rate limited"}} = SkillKit.LLM.Mock.stream([], [])
    end
  end

  describe "assert_response/2" do
    setup :verify_on_exit!

    test "runs assertion callback before returning response" do
      test_pid = self()

      SkillKit.Test.assert_response(%Text{content: "4"}, fn messages, opts ->
        send(test_pid, {:asserted, messages, opts})
      end)

      {:ok, _stream} = SkillKit.LLM.Mock.stream([%{role: "user"}], model: "test")

      assert_receive {:asserted, [%{role: "user"}], [model: "test"]}
    end

    test "returns correct response after assertion" do
      SkillKit.Test.assert_response(%Text{content: "Hello"}, fn _messages, _opts -> :ok end)

      {:ok, stream} = SkillKit.LLM.Mock.stream([], [])
      result = Decoder.decode_events(Enum.to_list(stream))

      assert %Message.Assistant{content: "Hello"} = result
    end
  end

  describe "expect_responses/1" do
    setup :verify_on_exit!

    test "sets up sequential Mox expectations" do
      SkillKit.Test.expect_responses([
        %ToolCall{name: "echo", input: %{"cmd" => "hi"}},
        %Text{content: "Done!"}
      ])

      # First call returns tool call
      {:ok, stream1} = SkillKit.LLM.Mock.stream([], [])
      result1 = Decoder.decode_events(Enum.to_list(stream1))
      assert %Message.Assistant{tool_calls: [tc]} = result1
      assert tc.name == "echo"

      # Second call returns text
      {:ok, stream2} = SkillKit.LLM.Mock.stream([], [])
      result2 = Decoder.decode_events(Enum.to_list(stream2))
      assert %Message.Assistant{content: "Done!"} = result2
    end
  end

  describe "expect_error/2" do
    setup :verify_on_exit!

    test "sets up Mox expectation returning error tuple" do
      SkillKit.Test.expect_error(500, "internal error")

      assert {:error, {500, "internal error"}} = SkillKit.LLM.Mock.stream([], [])
    end
  end
end
