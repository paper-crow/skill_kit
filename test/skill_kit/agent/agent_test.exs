defmodule SkillKit.Agent.AgentTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent
  alias SkillKit.Agent.Definition

  setup do
    registry_name = :"agent_test_registry_#{:erlang.unique_integer([:positive])}"
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
    test "starts full agent tree with all components registered", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      opts = %{
        agent_name: agent_name,
        definition: definition,
        depth: 0,
        parent_name: nil,
        scope: nil,
        backends: [],
        registry: registry
      }

      {:ok, _sup} = Agent.start_link(opts)

      assert [{_, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :server})
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :subagent_supervisor})
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :skill_registry})
    end

    test "mailbox can deliver messages to server", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      opts = %{
        agent_name: agent_name,
        definition: definition,
        depth: 0,
        parent_name: nil,
        scope: nil,
        backends: [],
        registry: registry
      }

      {:ok, _sup} = Agent.start_link(opts)

      [{mailbox_pid, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})

      GenServer.cast(mailbox_pid, {:message, "hello"})
      GenServer.cast(mailbox_pid, {:message, "world"})
      send(mailbox_pid, :flush)

      Process.sleep(50)
      state = :sys.get_state(server_pid)
      assert state.messages == ["hello", "world"]
    end

    test "server state has correct depth and scope", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      scope = %{user_id: "user-1", tenant_id: "tenant-1"}

      opts = %{
        agent_name: agent_name,
        definition: definition,
        depth: 2,
        parent_name: "parent-agent",
        scope: scope,
        backends: [],
        registry: registry
      }

      {:ok, _sup} = Agent.start_link(opts)

      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})
      state = :sys.get_state(server_pid)

      assert state.depth == 2
      assert state.parent_name == "parent-agent"
      assert state.scope == scope
    end
  end
end
