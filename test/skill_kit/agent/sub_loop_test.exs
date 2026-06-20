defmodule SkillKit.Agent.SubLoopTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Agent, as: SkAgent
  alias SkillKit.Agent.Server
  alias SkillKit.Agent.SubLoop
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Event.ToolCallStart
  alias SkillKit.Types.UserMessage

  setup :verify_on_exit!

  defmodule FakeTool do
    @moduledoc false
    @behaviour SkillKit.Tool

    @impl SkillKit.Tool
    def definition do
      %SkillKit.Tool{
        name: "fake_tool",
        description: "echoes its input",
        input_schema: %{"type" => "object", "properties" => %{}}
      }
    end

    @impl SkillKit.Tool
    def execute(%SkillKit.ToolExecution{input: input}) do
      {:ok, Map.get(input, "payload", "ok")}
    end

    @impl SkillKit.Tool
    def resume(_exec, _state, _decision), do: {:error, "resume not supported"}
  end

  defp parent_state do
    agent = %SkAgent{
      name: "parent",
      description: "t",
      system_prompt: "You are the parent.",
      caller: self()
    }

    %Server{agent: agent, messages: []}
  end

  defp config(overrides \\ %{}) do
    base = %{
      system_append: "the body",
      initial_messages: [%UserMessage{content: "hi"}],
      sub_tools: [{FakeTool, %{agent_name: "parent"}, FakeTool.definition()}],
      sub_name: "parent/sub:x",
      error_prefix: "Sub-loop error"
    }

    Map.merge(base, overrides)
  end

  test "forwards ToolCallStart and ToolCallComplete events to caller with sub_name tag" do
    expect(SkillKit.LLM.Mock, :stream, 2, fn _msgs, _opts ->
      count = (Process.get(:calls) || 0) + 1
      Process.put(:calls, count)

      events =
        case count do
          1 ->
            [
              %ToolCallStart{id: "tc_1", name: "fake_tool"},
              %ToolCallComplete{id: "tc_1", name: "fake_tool", input: %{"payload" => "hello"}},
              %Done{stop_reason: :tool_use}
            ]

          2 ->
            [%Delta{text: "done"}, %Done{stop_reason: :end_turn}]
        end

      {:ok, Stream.map(events, & &1)}
    end)

    SubLoop.run(parent_state(), config())

    assert_receive %ToolCallStart{agent: "parent/sub:x", id: "tc_1", name: "fake_tool"}
    assert_receive %ToolCallComplete{agent: "parent/sub:x", id: "tc_1", name: "fake_tool"}
  end

  test "uses the config's :model for the LLM call, overriding the parent agent's model" do
    agent = %SkAgent{
      name: "parent",
      description: "t",
      system_prompt: "You are the parent.",
      model: "mock://parent-model",
      caller: self()
    }

    state = %Server{agent: agent, messages: []}
    pid = self()

    expect(SkillKit.LLM.Mock, :stream, fn _msgs, opts ->
      send(pid, {:model_opt, Keyword.get(opts, :model)})
      {:ok, Stream.map([%Delta{text: "ok"}, %Done{stop_reason: :end_turn}], & &1)}
    end)

    SubLoop.run(state, config(%{model: "mock://override-model"}))

    assert_receive {:model_opt, "override-model"}
  end

  test "falls back to the parent agent's model when the config omits :model" do
    agent = %SkAgent{
      name: "parent",
      description: "t",
      system_prompt: "You are the parent.",
      model: "mock://parent-model",
      caller: self()
    }

    state = %Server{agent: agent, messages: []}
    pid = self()

    expect(SkillKit.LLM.Mock, :stream, fn _msgs, opts ->
      send(pid, {:model_opt, Keyword.get(opts, :model)})
      {:ok, Stream.map([%Delta{text: "ok"}, %Done{stop_reason: :end_turn}], & &1)}
    end)

    # config/1 omits :model, mirroring the server.ex event sub-loop caller.
    SubLoop.run(state, config())

    assert_receive {:model_opt, "parent-model"}
  end

  test "runs with empty initial_messages" do
    expect(SkillKit.LLM.Mock, :stream, fn messages, _opts ->
      send(self(), {:llm_called_with, messages})
      {:ok, Stream.map([%Delta{text: "ok"}, %Done{stop_reason: :end_turn}], & &1)}
    end)

    result = SubLoop.run(parent_state(), config(%{initial_messages: []}))

    assert result == "ok"
    assert_receive {:llm_called_with, []}
  end
end
