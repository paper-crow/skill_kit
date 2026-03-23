defmodule SkillKit.Agent.SubagentSupervisorTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.SubagentSupervisor

  setup do
    registry_name = :"subsup_test_registry_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_name = "test-agent-#{:erlang.unique_integer([:positive])}"

    {:ok, registry: registry_name, agent_name: agent_name}
  end

  describe "start_link" do
    test "registers in the agent registry via :via naming", %{
      registry: registry,
      agent_name: agent_name
    } do
      {:ok, pid} = SubagentSupervisor.start_link({agent_name, registry})

      assert [{^pid, _}] = Registry.lookup(registry, {agent_name, :subagent_supervisor})
    end

    test "can start children dynamically", %{registry: registry, agent_name: agent_name} do
      {:ok, pid} = SubagentSupervisor.start_link({agent_name, registry})

      spec = %{id: :test_task, start: {Task, :start_link, [fn -> Process.sleep(:infinity) end]}}
      assert {:ok, _child} = DynamicSupervisor.start_child(pid, spec)
      assert [_] = DynamicSupervisor.which_children(pid)
    end
  end
end
