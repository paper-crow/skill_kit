defmodule SkillKit.Agent.ToolRouterTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.ToolRouter
  alias SkillKit.LLM.Message

  describe "execute/3" do
    test "executes local tool calls and returns results" do
      tool_calls = [
        %Message.ToolCall{id: "tc_1", name: "echo", input: %{"text" => "hello"}}
      ]

      local_handler = fn %Message.ToolCall{id: id, input: input} ->
        %Message.ToolResult{tool_call_id: id, content: input["text"]}
      end

      classifier = fn _tc -> :local end

      {results, _state} = ToolRouter.execute(tool_calls, %{subagents: %{}}, classifier, local_handler)

      assert [%Message.ToolResult{tool_call_id: "tc_1", content: "hello"}] = results
    end

    test "returns placeholder results for subagent tool calls" do
      tool_calls = [
        %Message.ToolCall{id: "tc_1", name: "project-a", input: %{"task" => "deploy"}}
      ]

      classifier = fn _tc -> :subagent end
      local_handler = fn _tc -> raise "should not be called" end

      spawner = fn tc, state ->
        task_ref = make_ref()
        placeholder = %Message.ToolResult{
          tool_call_id: tc.id,
          content: "Delegated to agent '#{tc.name}'. Task ref: #{inspect(task_ref)}."
        }
        {placeholder, state}
      end

      {results, _state} = ToolRouter.execute(tool_calls, %{subagents: %{}}, classifier, local_handler, spawner)

      assert [%Message.ToolResult{tool_call_id: "tc_1"}] = results
      assert hd(results).content =~ "Delegated"
    end

    test "handles mixed local and subagent tool calls" do
      tool_calls = [
        %Message.ToolCall{id: "tc_1", name: "echo", input: %{"text" => "hi"}},
        %Message.ToolCall{id: "tc_2", name: "project-a", input: %{"task" => "build"}}
      ]

      classifier = fn
        %{name: "echo"} -> :local
        _ -> :subagent
      end

      local_handler = fn %Message.ToolCall{id: id, input: input} ->
        %Message.ToolResult{tool_call_id: id, content: input["text"]}
      end

      spawner = fn tc, state ->
        placeholder = %Message.ToolResult{
          tool_call_id: tc.id,
          content: "Delegated to agent '#{tc.name}'."
        }
        {placeholder, state}
      end

      {results, _state} = ToolRouter.execute(tool_calls, %{subagents: %{}}, classifier, local_handler, spawner)

      assert length(results) == 2
      assert Enum.find(results, &(&1.tool_call_id == "tc_1")).content == "hi"
      assert Enum.find(results, &(&1.tool_call_id == "tc_2")).content =~ "Delegated"
    end

    test "wraps local handler errors as error results" do
      tool_calls = [
        %Message.ToolCall{id: "tc_1", name: "fail", input: %{}}
      ]

      local_handler = fn _tc -> raise "boom" end
      classifier = fn _tc -> :local end

      {results, _state} = ToolRouter.execute(tool_calls, %{subagents: %{}}, classifier, local_handler)

      assert [%Message.ToolResult{tool_call_id: "tc_1", is_error: true}] = results
      assert hd(results).content =~ "boom"
    end
  end
end
