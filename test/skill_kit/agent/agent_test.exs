defmodule SkillKit.Agent.AgentTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Agent
  alias SkillKit.Agent.Definition
  alias SkillKit.LLM.Message

  setup :verify_on_exit!

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
        sources: [],
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
      expect(SkillKit.LLM.Mock, :stream, fn _config, _messages, _opts ->
        events = [
          %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}},
          %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
          %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "OK"}},
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
          %{"type" => "message_stop"}
        ]
        {:ok, Stream.map(events, & &1)}
      end)

      opts = %{
        agent_name: agent_name,
        definition: definition,
        depth: 0,
        parent_name: nil,
        scope: nil,
        sources: [],
        registry: registry,
        provider: {SkillKit.LLM.Mock, []}
      }

      {:ok, _sup} = Agent.start_link(opts)

      [{mailbox_pid, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})
      Mox.allow(SkillKit.LLM.Mock, self(), server_pid)

      GenServer.cast(mailbox_pid, {:message, %Message.User{content: "hello"}})
      GenServer.cast(mailbox_pid, {:message, %Message.User{content: "world"}})
      send(mailbox_pid, :flush)

      Process.sleep(50)
      state = :sys.get_state(server_pid)
      assert Enum.any?(state.messages, &match?(%Message.User{content: "hello"}, &1))
      assert Enum.any?(state.messages, &match?(%Message.User{content: "world"}, &1))
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
        sources: [],
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
