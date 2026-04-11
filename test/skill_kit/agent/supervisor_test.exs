defmodule SkillKit.Agent.SupervisorTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Agent.Definition
  alias SkillKit.Agent.Supervisor, as: AgentSupervisor
  alias SkillKit.Types.UserMessage

  setup :verify_on_exit!

  setup do
    registry_name = :"agent_test_registry_#{:erlang.unique_integer([:positive])}"

    agent_name = "test-agent-#{:erlang.unique_integer([:positive])}"

    definition = %Definition{
      name: agent_name,
      description: "Test agent",
      system_prompt: "You are a test.",
      path: "/tmp/test",
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
        skills: [],
        registry: registry
      }

      {:ok, _sup} = AgentSupervisor.start_link(opts)

      assert [{_, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :server})
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :subagent_supervisor})
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :catalog})
    end

    test "mailbox can deliver messages to server", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        events = [
          %SkillKit.Event.Delta{text: "OK"},
          %SkillKit.Event.Done{stop_reason: :end_turn}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      opts = %{
        agent_name: agent_name,
        definition: definition,
        depth: 0,
        parent_name: nil,
        scope: nil,
        skills: [],
        registry: registry
      }

      {:ok, _sup} = AgentSupervisor.start_link(opts)

      [{mailbox_pid, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})
      Mox.allow(SkillKit.LLM.Mock, self(), server_pid)

      GenServer.cast(mailbox_pid, {:message, %UserMessage{content: "hello"}})
      GenServer.cast(mailbox_pid, {:message, %UserMessage{content: "world"}})
      send(mailbox_pid, :flush)

      Process.sleep(50)
      state = :sys.get_state(server_pid)
      assert Enum.any?(state.messages, &match?(%UserMessage{content: "hello"}, &1))
      assert Enum.any?(state.messages, &match?(%UserMessage{content: "world"}, &1))
    end

    test "server state has correct depth and scope", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      scope = %SkillKit.TestScope{user: "user-1", permissions: ["admin:read"]}

      opts = %{
        agent_name: agent_name,
        definition: definition,
        depth: 2,
        parent_name: "parent-agent",
        scope: scope,
        skills: [],
        registry: registry
      }

      {:ok, _sup} = AgentSupervisor.start_link(opts)

      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})
      state = :sys.get_state(server_pid)

      assert state.depth == 2
      assert state.parent_name == "parent-agent"
      assert state.scope == scope
    end
  end
end
