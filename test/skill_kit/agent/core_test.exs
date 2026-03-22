defmodule SkillKit.Agent.CoreTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.{Core, Definition}

  setup do
    registry_name = :"core_test_registry_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_name = "test-agent-#{:erlang.unique_integer([:positive])}"

    definition = %Definition{
      name: agent_name,
      description: "Test agent",
      system_prompt: "You are a test.",
      path: "/tmp/test",
      workspace: "/tmp/test",
      mailbox: %{max_messages: 10, flush_interval: 500}
    }

    {:ok, registry: registry_name, agent_name: agent_name, definition: definition}
  end

  describe "start_link" do
    test "starts all three children and registers them", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      {:ok, _sup} = Core.start_link({agent_name, definition, 0, nil, nil, registry})

      assert [{_, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :server})
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :subagent_supervisor})
    end

    test "mailbox can flush to server via registry", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      {:ok, _sup} = Core.start_link({agent_name, definition, 0, nil, nil, registry})

      [{mailbox_pid, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})

      GenServer.cast(mailbox_pid, {:message, "test"})
      send(mailbox_pid, :flush)
      Process.sleep(50)

      state = :sys.get_state(server_pid)
      assert "test" in state.messages
    end
  end
end
