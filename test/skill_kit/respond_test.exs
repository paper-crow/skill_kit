defmodule SkillKit.RespondTest do
  use ExUnit.Case, async: true

  import Mox
  import SkillKit.Test

  alias SkillKit.Agent
  alias SkillKit.Event.InputRequested
  alias SkillKit.Kit
  alias SkillKit.Kit.Memory
  alias SkillKit.Response.Text
  alias SkillKit.Response.ToolCall
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.ToolResult
  alias SkillKit.Types.UserMessage

  setup :verify_on_exit!

  defmodule SuspendTool do
    @moduledoc false
    @behaviour SkillKit.Tool

    alias SkillKit.Tool
    alias SkillKit.ToolExecution

    @impl true
    def definition do
      %Tool{
        name: "deploy",
        description: "Deploy tool that needs environment confirmation",
        input_schema: %{"type" => "object", "properties" => %{}}
      }
    end

    @impl true
    def execute(%ToolExecution{}) do
      {:pending, %{question: "Which environment?"}}
    end

    @impl true
    def resume(_execution, _state, answer) do
      {:ok, "Deployed to #{answer}"}
    end
  end

  defmodule FailResumeTool do
    @moduledoc false
    @behaviour SkillKit.Tool

    alias SkillKit.Tool
    alias SkillKit.ToolExecution

    @impl true
    def definition do
      %Tool{
        name: "fail_deploy",
        description: "Tool that fails on resume",
        input_schema: %{"type" => "object", "properties" => %{}}
      }
    end

    @impl true
    def execute(%ToolExecution{}) do
      {:pending, %{question: "Confirm?"}}
    end

    @impl true
    def resume(_execution, _state, _answer) do
      {:error, "Connection lost"}
    end
  end

  defmodule MultiStepTool do
    @moduledoc false
    @behaviour SkillKit.Tool

    alias SkillKit.Tool
    alias SkillKit.ToolExecution

    @impl true
    def definition do
      %Tool{
        name: "multi_step",
        description: "Tool requiring multiple inputs",
        input_schema: %{"type" => "object", "properties" => %{}}
      }
    end

    @impl true
    def execute(%ToolExecution{}) do
      {:pending, %{step: 1, question: "First question?"}}
    end

    @impl true
    def resume(_execution, %{step: 1}, answer) do
      {:pending, %{step: 2, question: "Second question?", first_answer: answer}}
    end

    def resume(_execution, %{step: 2} = state, answer) do
      {:ok, "Done with #{state.first_answer} and #{answer}"}
    end
  end

  describe "respond/3" do
    test "resumes a suspended tool and continues the LLM loop" do
      {:ok, mem} = Memory.start_link([])

      Memory.put_kit(mem, %Kit{
        name: "test",
        metadata: %{tool: SuspendTool}
      })

      # First LLM call: returns tool call to deploy
      # Second LLM call (after resume provides the tool result): returns final text
      expect_responses([
        %ToolCall{name: "deploy", input: %{}},
        %Text{content: "Deployment complete!"}
      ])

      {:ok, _pid, ctx} =
        start_server(
          tools: [{Memory, provider: mem}],
          caller: self()
        )

      server_pid = find_server(ctx)

      send(server_pid, {:mailbox_flush, [%UserMessage{content: "deploy the app"}]})

      # Should receive InputRequested when tool suspends
      assert_receive %InputRequested{
                       tool_call_id: tool_call_id,
                       tool_name: "deploy",
                       suspended_state: %{question: "Which environment?"}
                     },
                     2000

      # Respond with the answer — routed to blocked child via Registry
      respond_to_tool(ctx, tool_call_id, "us-east")

      # Should receive the resumed tool result notification
      assert_receive %ToolResult{content: "Deployed to us-east"}, 2000

      # Should receive the final response after the LLM loop continues
      assert_receive %AssistantMessage{content: "Deployment complete!"}, 2000
    end

    test "handles error result from resumed tool" do
      {:ok, mem} = Memory.start_link([])

      Memory.put_kit(mem, %Kit{
        name: "fail_test",
        metadata: %{tool: FailResumeTool}
      })

      expect_responses([
        %ToolCall{name: "fail_deploy", input: %{}},
        %Text{content: "Sorry, deployment failed."}
      ])

      {:ok, _pid, ctx} =
        start_server(
          tools: [{Memory, provider: mem}],
          caller: self()
        )

      server_pid = find_server(ctx)

      send(server_pid, {:mailbox_flush, [%UserMessage{content: "deploy"}]})

      assert_receive %InputRequested{tool_call_id: tool_call_id}, 2000

      respond_to_tool(ctx, tool_call_id, "yes")

      assert_receive %ToolResult{content: "Resume failed: \"Connection lost\"", is_error: true},
                     2000

      assert_receive %AssistantMessage{content: "Sorry, deployment failed."}, 2000
    end

    test "re-suspends when resumed tool returns {:pending, state}" do
      {:ok, mem} = Memory.start_link([])

      Memory.put_kit(mem, %Kit{
        name: "multi_test",
        metadata: %{tool: MultiStepTool}
      })

      expect_responses([
        %ToolCall{name: "multi_step", input: %{}},
        %Text{content: "All steps complete!"}
      ])

      {:ok, _pid, ctx} =
        start_server(
          tools: [{Memory, provider: mem}],
          caller: self()
        )

      server_pid = find_server(ctx)

      send(server_pid, {:mailbox_flush, [%UserMessage{content: "start"}]})

      # First suspension
      assert_receive %InputRequested{
                       tool_call_id: tool_call_id,
                       suspended_state: %{step: 1}
                     },
                     2000

      # Respond to first question -> re-suspends
      respond_to_tool(ctx, tool_call_id, "alpha")

      assert_receive %InputRequested{
                       tool_call_id: ^tool_call_id,
                       suspended_state: %{step: 2, first_answer: "alpha"}
                     },
                     2000

      # Respond to second question -> completes
      respond_to_tool(ctx, tool_call_id, "beta")

      assert_receive %ToolResult{content: "Done with alpha and beta"}, 2000
      assert_receive %AssistantMessage{content: "All steps complete!"}, 2000
    end

    test "respond returns :error for unknown tool_call_id" do
      {:ok, _pid, ctx} = start_server(caller: self())

      assert [] =
               Registry.lookup(ctx.registry, {ctx.agent_name, :pending_tool, "nonexistent_id"})
    end
  end

  describe "SkillKit.respond/3 public API" do
    test "returns {:error, :not_found} for stopped agent" do
      {:ok, agent} =
        SkillKit.start_agent(%Agent{
          name: "dead-respond-#{:erlang.unique_integer([:positive])}",
          description: "Test",
          system_prompt: "Test"
        })

      SkillKit.stop_agent(agent)
      Process.sleep(50)

      assert {:error, :not_found} = SkillKit.respond(agent, "tc_123", "answer")
    end
  end

  defp find_server(%{registry: registry, agent_name: name}) do
    [{pid, _}] = Registry.lookup(registry, {name, :server})
    pid
  end

  defp respond_to_tool(%{registry: registry, agent_name: name}, tool_call_id, answer) do
    [{pid, _}] = Registry.lookup(registry, {name, :pending_tool, tool_call_id})
    send(pid, {:resume, answer})
  end
end
