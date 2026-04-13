defmodule SkillKit.Runtime.LocalTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent
  alias SkillKit.Runtime

  describe "start_agent/1 via Runtime" do
    test "starts agent and returns AgentRef" do
      agent = %Agent{
        name: "runtime-test-#{:erlang.unique_integer([:positive])}",
        description: "Test",
        system_prompt: "Test",
        registry: :"runtime_test_reg_#{:erlang.unique_integer([:positive])}"
      }

      assert {:ok, ref} = Runtime.start_agent(agent)
      assert ref.name == agent.name
      assert ref.registry == agent.registry
      assert is_pid(ref.supervisor_pid)

      assert [{_, _}] = Registry.lookup(agent.registry, {agent.name, :server})
      assert [{_, _}] = Registry.lookup(agent.registry, {agent.name, :mailbox})

      Supervisor.stop(ref.supervisor_pid)
    end
  end
end
