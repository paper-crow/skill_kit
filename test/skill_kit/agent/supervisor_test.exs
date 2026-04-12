defmodule SkillKit.Agent.SupervisorTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Agent
  alias SkillKit.Agent.Supervisor, as: AgentSupervisor
  alias SkillKit.Types.UserMessage

  setup :verify_on_exit!

  setup do
    agent_name = "test-agent-#{:erlang.unique_integer([:positive])}"
    registry_name = :"agent_test_registry_#{:erlang.unique_integer([:positive])}"

    agent = %Agent{
      name: agent_name,
      description: "Test agent",
      system_prompt: "You are a test.",
      mailbox: %{max_messages: 10, flush_interval: 500},
      registry: registry_name
    }

    {:ok, agent: agent, agent_name: agent_name, registry: registry_name}
  end

  describe "start_link" do
    test "starts full agent tree with all components registered", %{
      agent: agent,
      agent_name: agent_name,
      registry: registry
    } do
      {:ok, _sup} = AgentSupervisor.start_link(agent)

      assert [{_, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :server})
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :tool_runner})
      assert [{_, _}] = Registry.lookup(registry, {agent_name, :catalog})
    end

    test "mailbox can deliver messages to server", %{
      agent: agent,
      agent_name: agent_name,
      registry: registry
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        events = [
          %SkillKit.Event.Delta{text: "OK"},
          %SkillKit.Event.Done{stop_reason: :end_turn}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, _sup} = AgentSupervisor.start_link(agent)

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
      agent_name: agent_name,
      registry: registry
    } do
      scope = %SkillKit.TestScope{user: "user-1", permissions: ["admin:read"]}

      agent = %Agent{
        name: agent_name,
        description: "Test agent",
        system_prompt: "You are a test.",
        mailbox: %{max_messages: 10, flush_interval: 500},
        registry: registry,
        depth: 2,
        parent_ref: %SkillKit.AgentRef{
          name: "parent-agent",
          registry: registry,
          supervisor_pid: self()
        },
        scope: scope
      }

      {:ok, _sup} = AgentSupervisor.start_link(agent)

      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})
      state = :sys.get_state(server_pid)

      assert state.agent.depth == 2
      assert state.agent.parent_ref.name == "parent-agent"
      assert state.agent.scope == scope
    end
  end
end
