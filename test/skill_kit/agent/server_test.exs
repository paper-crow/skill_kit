defmodule SkillKit.Agent.ServerTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.{Definition, Server}

  setup do
    registry_name = :"server_test_registry_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_name = "test-agent-#{:erlang.unique_integer([:positive])}"

    definition = %Definition{
      name: agent_name,
      description: "Test agent",
      system_prompt: "You are a test agent.",
      path: "/tmp/test",
      workspace: "/tmp/test"
    }

    {:ok, registry: registry_name, agent_name: agent_name, definition: definition}
  end

  describe "init" do
    test "registers in the agent registry", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      {:ok, pid} = Server.start_link({agent_name, definition, 0, nil, nil, registry})

      assert [{^pid, _}] = Registry.lookup(registry, {agent_name, :server})
    end

    test "initializes with correct state", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      {:ok, pid} = Server.start_link({agent_name, definition, 0, nil, :test_scope, registry})

      state = :sys.get_state(pid)
      assert state.agent_name == agent_name
      assert state.definition == definition
      assert state.depth == 0
      assert state.parent_name == nil
      assert state.scope == :test_scope
      assert state.messages == []
      assert state.subagents == %{}
    end
  end

  describe "mailbox_flush" do
    test "receives flush messages", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      {:ok, pid} = Server.start_link({agent_name, definition, 0, nil, nil, registry})

      send(pid, {:mailbox_flush, ["hello", "world"]})

      Process.sleep(10)
      state = :sys.get_state(pid)

      assert state.messages == ["hello", "world"]
    end
  end
end
