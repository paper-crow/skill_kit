defmodule SkillKit.TestTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Event.ToolCallStart
  alias SkillKit.LLM.Mock
  alias SkillKit.Response.Error
  alias SkillKit.Response.Text
  alias SkillKit.Response.ToolCall
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.UserMessage

  describe "expect_response/1" do
    setup :verify_on_exit!

    test "sets up Mox expectation for Text" do
      SkillKit.Test.expect_response(%Text{content: "Hello"})

      {:ok, stream} = Mock.stream([], [])
      events = Enum.to_list(stream)

      assert [%Delta{text: "Hello"}, %Done{stop_reason: :end_turn}] = events
    end

    test "sets up Mox expectation for ToolCall" do
      SkillKit.Test.expect_response(%ToolCall{name: "bash", input: %{"cmd" => "ls"}})

      {:ok, stream} = Mock.stream([], [])
      events = Enum.to_list(stream)

      assert [%ToolCallStart{name: "bash"}, %ToolCallComplete{name: "bash"}, %Done{}] = events
      assert %ToolCallComplete{input: %{"cmd" => "ls"}} = Enum.at(events, 1)
    end

    test "sets up Mox expectation for Error" do
      SkillKit.Test.expect_response(%Error{status: 429, message: "rate limited"})

      assert {:error, {429, "rate limited"}} = Mock.stream([], [])
    end
  end

  describe "assert_response/2" do
    setup :verify_on_exit!

    test "runs assertion callback before returning response" do
      test_pid = self()

      SkillKit.Test.assert_response(%Text{content: "4"}, fn messages, opts ->
        send(test_pid, {:asserted, messages, opts})
      end)

      {:ok, _stream} = Mock.stream([%{role: "user"}], model: "test")

      assert_receive {:asserted, [%{role: "user"}], [model: "test"]}
    end

    test "returns correct response after assertion" do
      SkillKit.Test.assert_response(%Text{content: "Hello"}, fn _messages, _opts -> :ok end)

      {:ok, stream} = Mock.stream([], [])
      events = Enum.to_list(stream)

      assert [%Delta{text: "Hello"}, %Done{stop_reason: :end_turn}] = events
    end
  end

  describe "expect_responses/1" do
    setup :verify_on_exit!

    test "sets up sequential Mox expectations" do
      SkillKit.Test.expect_responses([
        %ToolCall{name: "echo", input: %{"cmd" => "hi"}},
        %Text{content: "Done!"}
      ])

      # First call returns tool call events
      {:ok, stream1} = Mock.stream([], [])
      events1 = Enum.to_list(stream1)
      assert [%ToolCallStart{}, %ToolCallComplete{name: "echo"}, %Done{}] = events1

      # Second call returns text events
      {:ok, stream2} = Mock.stream([], [])
      events2 = Enum.to_list(stream2)
      assert [%Delta{text: "Done!"}, %Done{stop_reason: :end_turn}] = events2
    end
  end

  describe "expect_error/2" do
    setup :verify_on_exit!

    test "sets up Mox expectation returning error tuple" do
      SkillKit.Test.expect_error(500, "internal error")

      assert {:error, {500, "internal error"}} = Mock.stream([], [])
    end
  end

  describe "start_server/1" do
    setup :verify_on_exit!

    test "starts a registered Server with unique registry" do
      SkillKit.Test.expect_response(%Text{content: "Hi"})

      {:ok, pid, context} = SkillKit.Test.start_server(caller: self())

      assert Process.alive?(pid)
      assert is_atom(context.registry)
      assert is_binary(context.agent_name)

      send(pid, {:mailbox_flush, [%UserMessage{content: "hello"}]})

      assert_receive %AssistantMessage{content: "Hi"}, 1000
    end

    test "accepts custom options" do
      {:ok, pid, context} =
        SkillKit.Test.start_server(
          agent_name: "custom-agent",
          scope: %SkillKit.TestScope{permissions: ["test:read"]}
        )

      assert Process.alive?(pid)
      assert context.agent_name == "custom-agent"

      state = :sys.get_state(pid)
      assert state.scope == %SkillKit.TestScope{permissions: ["test:read"]}
    end
  end
end
