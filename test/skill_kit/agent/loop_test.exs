defmodule SkillKit.Agent.LoopTest do
  use ExUnit.Case, async: true

  import Mox
  import SkillKit.TelemetryHelper

  alias SkillKit.Event.Delta
  alias SkillKit.Event.Done
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.UserMessage

  setup :verify_on_exit!
  setup :telemetry

  setup do
    registry_name = :"loop_test_registry_#{:erlang.unique_integer([:positive])}"

    agent_name = "loop-test-agent-#{:erlang.unique_integer([:positive])}"

    agent = %SkillKit.Agent{
      name: agent_name,
      description: "Test agent for loop",
      system_prompt: "You are a helpful test agent.",
      path: "/tmp/test",
      mailbox: %{max_messages: 10, flush_interval: 60_000},
      registry: registry_name
    }

    {:ok, agent: agent, registry: registry_name, agent_name: agent_name}
  end

  describe "full agent tree with loop" do
    test "message flows through mailbox -> server -> LLM -> response", %{
      agent: agent,
      registry: registry,
      agent_name: agent_name
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

      {:ok, _sup} = SkillKit.Agent.Supervisor.start_link(agent)

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

    @tag telemetry: [
           [:skill_kit, :turn, :start],
           [:skill_kit, :llm_request, :stop],
           [:skill_kit, :turn, :stop]
         ]
    test "telemetry events fire during loop", %{
      agent: agent,
      registry: registry,
      agent_name: agent_name
    } do
      expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        events = [
          %Delta{text: "ok"},
          %Done{stop_reason: :end_turn}
        ]

        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, _sup} = SkillKit.Agent.Supervisor.start_link(agent)

      [{mailbox_pid, _}] = Registry.lookup(registry, {agent_name, :mailbox})
      [{server_pid, _}] = Registry.lookup(registry, {agent_name, :server})
      Mox.allow(SkillKit.LLM.Mock, self(), server_pid)

      GenServer.cast(mailbox_pid, {:message, %UserMessage{content: "hi"}})
      send(mailbox_pid, :flush)

      assert_receive {__MODULE__, [:skill_kit, :turn, :start], %{agent_name: ^agent_name}},
                     500

      assert_receive {__MODULE__, [:skill_kit, :llm_request, :stop], %{agent_name: ^agent_name}},
                     500

      assert_receive {__MODULE__, [:skill_kit, :turn, :stop], %{agent_name: ^agent_name}},
                     500
    end
  end
end
