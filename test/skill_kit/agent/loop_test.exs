defmodule SkillKit.Agent.LoopTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Agent
  alias SkillKit.Agent.Definition
  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.UserMessage

  setup :verify_on_exit!

  setup do
    registry_name = :"loop_test_registry_#{:erlang.unique_integer([:positive])}"

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
    test "message flows through mailbox -> server -> LLM -> response", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn messages, _opts ->
        assert Enum.any?(messages, fn
                 %UserMessage{content: "What is 2+2?"} -> true
                 _ -> false
               end)

        events = [
          %Delta{text: "4"},
          %Done{stop_reason: :end_turn}
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
        registry: registry
      }

      {:ok, _sup} = Agent.start_link(opts)

      [{mailbox_pid, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})
      Mox.allow(SkillKit.LLM.Mock, self(), server_pid)

      GenServer.cast(mailbox_pid, {:message, %UserMessage{content: "What is 2+2?"}})
      send(mailbox_pid, :flush)
      Process.sleep(100)

      state = :sys.get_state(server_pid)

      assert length(state.messages) == 2
      assert %UserMessage{content: "What is 2+2?"} = Enum.at(state.messages, 0)
      assert %AssistantMessage{content: "4"} = Enum.at(state.messages, 1)
    end

    test "telemetry events fire during loop", %{
      registry: registry,
      agent_name: agent_name,
      definition: definition
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        events = [
          %Delta{text: "ok"},
          %Done{stop_reason: :end_turn}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      test_pid = self()
      handler_id = "loop-test-#{agent_name}"

      SkillKit.Telemetry.attach_many(
        handler_id,
        [
          [:skill_kit, :agent, :turn, :start],
          [:skill_kit, :agent, :response],
          [:skill_kit, :agent, :turn, :stop]
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
        sources: [],
        registry: registry
      }

      {:ok, _sup} = Agent.start_link(opts)

      [{mailbox_pid, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})
      Mox.allow(SkillKit.LLM.Mock, self(), server_pid)

      GenServer.cast(mailbox_pid, {:message, %UserMessage{content: "hi"}})
      send(mailbox_pid, :flush)

      assert_receive {:telemetry, [:skill_kit, :agent, :turn, :start], _,
                      %{agent_name: ^agent_name}},
                     500

      assert_receive {:telemetry, [:skill_kit, :agent, :response], _, %{agent_name: ^agent_name}},
                     500

      assert_receive {:telemetry, [:skill_kit, :agent, :turn, :stop], %{duration: _},
                      %{agent_name: ^agent_name}},
                     500

      SkillKit.Telemetry.detach(handler_id)
    end
  end
end
