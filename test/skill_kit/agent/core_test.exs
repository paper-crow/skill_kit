defmodule SkillKit.Agent.CoreTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Agent.Core
  alias SkillKit.Agent.Definition
  alias SkillKit.LLM.Message

  setup :verify_on_exit!

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

      backend = {SkillKit.LLM.Mock, []}
      {:ok, _sup} = Core.start_link({agent_name, definition, 0, nil, nil, registry, backend: backend})

      [{mailbox_pid, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})
      Mox.allow(SkillKit.LLM.Mock, self(), server_pid)

      msg = %Message.User{content: "test"}
      GenServer.cast(mailbox_pid, {:message, msg})
      send(mailbox_pid, :flush)
      Process.sleep(50)

      state = :sys.get_state(server_pid)
      assert Enum.any?(state.messages, &match?(%Message.User{content: "test"}, &1))
    end
  end
end
