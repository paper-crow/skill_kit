defmodule SkillKit.Agent.ToolRunnerTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.ToolRunner

  setup do
    registry_name = :"tool_runner_test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_name = "test-agent-#{:erlang.unique_integer([:positive])}"

    agent = %SkillKit.Agent{
      name: agent_name,
      description: "Test",
      system_prompt: "Test",
      registry: registry_name
    }

    {:ok, agent: agent, agent_name: agent_name, registry: registry_name}
  end

  describe "start_link/1" do
    test "starts and registers in the agent registry", %{
      agent: agent,
      agent_name: agent_name,
      registry: registry
    } do
      {:ok, _pid} = ToolRunner.start_link(agent)

      assert [{pid, _}] = Registry.lookup(registry, {agent_name, :tool_runner})
      assert is_pid(pid)
    end
  end

  describe "start_child/2" do
    test "starts a supervised child task", %{agent: agent} do
      {:ok, runner_pid} = ToolRunner.start_link(agent)
      test_pid = self()

      {:ok, child_pid} =
        ToolRunner.start_child(runner_pid, fn ->
          send(test_pid, {:child_ran, self()})
          :ok
        end)

      assert is_pid(child_pid)
      assert_receive {:child_ran, ^child_pid}, 1000
    end

    test "child crash does not take down the runner", %{agent: agent} do
      {:ok, runner_pid} = ToolRunner.start_link(agent)

      {:ok, _child_pid} =
        ToolRunner.start_child(runner_pid, fn ->
          raise "boom"
        end)

      Process.sleep(50)
      assert Process.alive?(runner_pid)
    end
  end
end
