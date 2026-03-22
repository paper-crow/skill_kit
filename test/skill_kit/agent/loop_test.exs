defmodule SkillKit.Agent.LoopTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Agent
  alias SkillKit.Agent.Definition
  alias SkillKit.LLM.Message

  setup :verify_on_exit!

  setup do
    registry_name = :"loop_test_registry_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    agent_name = "loop-test-agent-#{:erlang.unique_integer([:positive])}"

    definition = %Definition{
      name: agent_name,
      description: "Test agent for loop",
      system_prompt: "You are a helpful test agent.",
      path: "/tmp/test",
      workspace: "/tmp/test",
      mailbox: %{max_messages: 10, flush_interval: 60_000}
    }

    {:ok, registry: registry_name, agent_name: agent_name, definition: definition}
  end

  describe "full agent tree with loop" do
    test "message flows through mailbox → server → LLM → response", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _config, messages, _opts ->
        assert Enum.any?(messages, fn
          %Message.User{content: "What is 2+2?"} -> true
          _ -> false
        end)

        events = [
          %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}},
          %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
          %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "4"}},
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
        backends: [],
        registry: registry,
        server_opts: [backend: {SkillKit.LLM.Mock, []}]
      }

      {:ok, _sup} = Agent.start_link(opts)

      [{mailbox_pid, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})
      Mox.allow(SkillKit.LLM.Mock, self(), server_pid)

      GenServer.cast(mailbox_pid, {:message, %Message.User{content: "What is 2+2?"}})
      send(mailbox_pid, :flush)
      Process.sleep(100)

      state = :sys.get_state(server_pid)

      assert length(state.messages) == 2
      assert %Message.User{content: "What is 2+2?"} = Enum.at(state.messages, 0)
      assert %Message.Assistant{content: "4"} = Enum.at(state.messages, 1)
    end

    test "telemetry events fire during loop", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _config, _messages, _opts ->
        events = [
          %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}},
          %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
          %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "ok"}},
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
          %{"type" => "message_stop"}
        ]
        {:ok, Stream.map(events, & &1)}
      end)

      test_pid = self()
      handler_id = "loop-test-#{agent_name}"

      :telemetry.attach_many(
        handler_id,
        [
          [:skill_kit, :agent, :turn_start],
          [:skill_kit, :agent, :response],
          [:skill_kit, :agent, :turn_end]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      opts = %{
        agent_name: agent_name,
        definition: definition,
        depth: 0,
        parent_name: nil,
        scope: nil,
        backends: [],
        registry: registry,
        server_opts: [backend: {SkillKit.LLM.Mock, []}]
      }

      {:ok, _sup} = Agent.start_link(opts)

      [{mailbox_pid, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})
      Mox.allow(SkillKit.LLM.Mock, self(), server_pid)

      GenServer.cast(mailbox_pid, {:message, %Message.User{content: "hi"}})
      send(mailbox_pid, :flush)

      assert_receive {:telemetry, [:skill_kit, :agent, :turn_start], _, %{agent_name: ^agent_name}}, 500
      assert_receive {:telemetry, [:skill_kit, :agent, :response], _, %{agent_name: ^agent_name}}, 500
      assert_receive {:telemetry, [:skill_kit, :agent, :turn_end], %{duration: _}, %{agent_name: ^agent_name}}, 500

      :telemetry.detach(handler_id)
    end
  end
end
