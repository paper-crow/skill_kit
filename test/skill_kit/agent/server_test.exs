defmodule SkillKit.Agent.ServerTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Agent.Definition
  alias SkillKit.Agent.Server
  alias SkillKit.LLM.Message

  setup :verify_on_exit!

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
  end

  describe "agent loop" do
    test "streams LLM response and appends to conversation", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _config, messages, _opts ->
        assert [%Message.User{content: "hello"}] = Enum.filter(messages, &match?(%Message.User{}, &1))

        events = [
          %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}},
          %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
          %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hi there!"}},
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
          %{"type" => "message_stop"}
        ]
        {:ok, Stream.map(events, & &1)}
      end)

      backend = {SkillKit.LLM.Mock, []}
      {:ok, pid} = Server.start_link({agent_name, definition, 0, nil, nil, registry, backend: backend})
      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "hello"}]})
      Process.sleep(50)

      state = :sys.get_state(pid)

      assert length(state.messages) == 2
      assert %Message.User{content: "hello"} = Enum.at(state.messages, 0)
      assert %Message.Assistant{content: "Hi there!"} = Enum.at(state.messages, 1)
    end

    test "executes local tool calls and loops", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      call_count = :counters.new(1, [:atomics])

      expect(SkillKit.LLM.Mock, :stream, 2, fn _config, _messages, _opts ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        events = if count == 1 do
          [
            %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}},
            %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "tool_use", "id" => "tc_1", "name" => "echo", "input" => %{}}},
            %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"text\": \"hi\"}"}},
            %{"type" => "content_block_stop", "index" => 0},
            %{"type" => "message_delta", "delta" => %{"stop_reason" => "tool_use"}},
            %{"type" => "message_stop"}
          ]
        else
          [
            %{"type" => "message_start", "message" => %{"id" => "msg_2", "role" => "assistant", "content" => []}},
            %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
            %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Done."}},
            %{"type" => "content_block_stop", "index" => 0},
            %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
            %{"type" => "message_stop"}
          ]
        end

        {:ok, Stream.map(events, & &1)}
      end)

      backend = {SkillKit.LLM.Mock, []}
      {:ok, pid} = Server.start_link({agent_name, definition, 0, nil, nil, registry, backend: backend})
      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      send(pid, {:mailbox_flush, [%Message.User{content: "do it"}]})
      Process.sleep(100)

      state = :sys.get_state(pid)

      assert length(state.messages) >= 4
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "subagent lifecycle" do
    test "subagent result arrives as System message through mailbox", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _config, _messages, _opts ->
        events = [
          %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}},
          %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
          %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Got it."}},
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
          %{"type" => "message_stop"}
        ]
        {:ok, Stream.map(events, & &1)}
      end)

      backend = {SkillKit.LLM.Mock, []}
      {:ok, pid} = Server.start_link({agent_name, definition, 0, nil, nil, registry, backend: backend})
      Mox.allow(SkillKit.LLM.Mock, self(), pid)

      system_msg = %Message.System{content: "[Background task ref_1 complete] Agent 'worker' returned: done"}
      send(pid, {:mailbox_flush, [system_msg]})
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert Enum.any?(state.messages, &match?(%Message.System{}, &1))
    end
  end
end
