defmodule SkillKit.SendEventTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Event.Delta
  alias SkillKit.Storage
  alias SkillKit.Types.AssistantMessage
  alias SkillKit.Types.UserMessage

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    start_supervised!(Storage.Memory)
    :ok
  end

  defp definition(name) do
    %SkillKit.Agent{
      name: name,
      description: "Test",
      system_prompt: "You are helpful.",
      model: "test-model"
    }
  end

  defp server_state(agent_ref) do
    [{pid, _}] = Registry.lookup(agent_ref.registry, {agent_ref.name, :server})
    :sys.get_state(pid)
  end

  test "send_event runs a sub-loop and bubbles the result to the main agent via a SystemMessage" do
    name = "send-event-#{System.unique_integer([:positive])}"

    # Sub-loop's LLM response is the first call; the main agent's
    # reaction (triggered by the bubble-up SystemMessage) is the second.
    SkillKit.Test.expect_responses([
      %SkillKit.Response.Text{content: "delivery processed"},
      %SkillKit.Response.Text{content: "Webhook delivered: processed OK."}
    ])

    {:ok, agent} = SkillKit.start_agent(definition(name), caller: self())

    assert :ok =
             SkillKit.send_event(agent, "<webhook-delivery id=\"dlv_abc\"/>",
               system_append: "Process this webhook.",
               sub_agent_name: "#{name}/delivery:wh_1"
             )

    # Sub-loop delta comes through tagged with sub-agent name
    assert_receive %Delta{text: "delivery processed", agent: sub_name}, 1000
    assert sub_name == "#{name}/delivery:wh_1"

    # Main agent's reaction to the bubbled SystemMessage comes through
    # tagged with the root agent name
    assert_receive %Delta{text: "Webhook delivered: processed OK.", agent: ^name}, 1000

    # Let the Server finish the main turn
    Process.sleep(100)

    state = server_state(agent)

    # Main agent's messages include the bubbled SystemMessage and the
    # main agent's assistant response. The sub-loop's intermediate
    # steps are NOT in the main conversation.
    assert Enum.any?(state.messages, fn
             %SkillKit.Types.SystemMessage{content: content} ->
               String.contains?(content, "delivery processed") and
                 String.contains?(content, "Event delivered")

             _ ->
               false
           end)

    assert Enum.any?(state.messages, fn
             %AssistantMessage{content: "Webhook delivered: processed OK." <> _} -> true
             _ -> false
           end)

    SkillKit.stop_agent(agent)
  end

  test "send_event returns {:error, :not_found} for a stopped agent" do
    name = "send-event-dead-#{System.unique_integer([:positive])}"
    {:ok, agent} = SkillKit.start_agent(definition(name))
    SkillKit.stop_agent(agent)
    Process.sleep(50)

    assert {:error, :not_found} =
             SkillKit.send_event(agent, "x", system_append: "p", sub_agent_name: "n")
  end

  test "send_event passes the configured system_append to the LLM as a system prompt suffix" do
    name = "send-event-sys-#{System.unique_integer([:positive])}"

    # Two LLM calls: sub-loop with system_append, main agent reaction.
    SkillKit.Test.expect_responses([
      %SkillKit.Response.Text{content: "ok"},
      %SkillKit.Response.Text{content: "main ack"}
    ])

    # We can't use assert_response because we need to assert on just
    # the FIRST call (sub-loop). Instead, capture the system from the
    # delta stream via the caller.
    {:ok, agent} = SkillKit.start_agent(definition(name), caller: self())

    assert :ok =
             SkillKit.send_event(agent, "pointer",
               system_append: "Handle this webhook event.",
               sub_agent_name: "#{name}/delivery:x"
             )

    assert_receive %Delta{text: "ok"}, 1000
    assert_receive %Delta{text: "main ack"}, 1000
    SkillKit.stop_agent(agent)
  end

  test "send_event with initial_messages: :empty sends only the event user message to LLM" do
    name = "send-event-empty-#{System.unique_integer([:positive])}"

    # Custom Mox expectation that asserts on the first call's messages
    # then returns ok; second call (main agent reaction) just returns text.
    counter = :counters.new(1, [:atomics])

    Mox.expect(SkillKit.LLM.Mock, :stream, 2, fn messages, _opts ->
      index = :counters.get(counter, 1) + 1
      :counters.put(counter, 1, index)

      case index do
        1 -> assert messages == [%UserMessage{content: "pointer"}]
        _ -> :ok
      end

      {:ok,
       Stream.map(
         [
           %SkillKit.Event.Delta{text: "ok-#{index}"},
           %SkillKit.Event.Done{stop_reason: :end_turn}
         ],
         & &1
       )}
    end)

    {:ok, agent} = SkillKit.start_agent(definition(name), caller: self())

    assert :ok =
             SkillKit.send_event(agent, "pointer",
               system_append: "Intent.",
               initial_messages: :empty,
               sub_agent_name: "#{name}/delivery:x"
             )

    assert_receive %Delta{text: "ok-1"}, 1000
    assert_receive %Delta{text: "ok-2"}, 1000
    SkillKit.stop_agent(agent)
  end
end
