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

  test "send_event sub-loop reaches the main agent only when it calls send_message" do
    name = "send-event-bubble-#{System.unique_integer([:positive])}"

    # Sub-loop turn 1 = ToolCall(send_message, content="processed OK")
    # Sub-loop turn 2 = empty assistant turn → loop terminates
    # Main agent turn = reaction to the UserMessage delivered by send_message
    SkillKit.Test.expect_responses([
      %SkillKit.Response.ToolCall{
        name: "send_message",
        input: %{"content" => "processed OK"}
      },
      %SkillKit.Response.Text{content: ""},
      %SkillKit.Response.Text{content: "Webhook delivered: processed OK."}
    ])

    {:ok, agent} = SkillKit.start_agent(definition(name), caller: self())

    assert :ok =
             SkillKit.send_event(agent, "<webhook-delivery id=\"dlv_abc\"/>",
               system_append: "Process this webhook.",
               sub_agent_name: "#{name}/delivery:wh_1"
             )

    assert_receive %Delta{text: "Webhook delivered: processed OK.", agent: ^name}, 1_000

    Process.sleep(100)

    state = server_state(agent)

    assert Enum.any?(state.messages, fn
             %UserMessage{content: "processed OK"} -> true
             _ -> false
           end)

    assert Enum.any?(state.messages, fn
             %AssistantMessage{content: "Webhook delivered: processed OK." <> _} -> true
             _ -> false
           end)

    SkillKit.stop_agent(agent)
  end

  test "send_event sub-loop that does not call send_message leaves the main agent idle" do
    name = "send-event-silent-#{System.unique_integer([:positive])}"

    # Only one LLM call (sub-loop). No main agent turn — the sub-loop ends
    # without invoking send_message, so nothing reaches the main mailbox.
    SkillKit.Test.expect_responses([
      %SkillKit.Response.Text{content: "handled silently"}
    ])

    {:ok, agent} = SkillKit.start_agent(definition(name), caller: self())

    sub_name = "#{name}/delivery:wh_silent"

    assert :ok =
             SkillKit.send_event(agent, "<webhook-delivery id=\"dlv_silent\"/>",
               system_append: "Just log it; do not bother the user.",
               sub_agent_name: sub_name
             )

    assert_receive %Delta{text: "handled silently", agent: ^sub_name}, 1_000

    refute_receive %Delta{agent: ^name}, 200

    Process.sleep(100)

    state = server_state(agent)

    refute Enum.any?(state.messages, fn
             %UserMessage{content: "handled silently"} -> true
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

    # Single sub-loop call; no auto-bubble means no main-agent turn.
    SkillKit.Test.expect_responses([
      %SkillKit.Response.Text{content: "ok"}
    ])

    {:ok, agent} = SkillKit.start_agent(definition(name), caller: self())

    assert :ok =
             SkillKit.send_event(agent, "pointer",
               system_append: "Handle this webhook event.",
               sub_agent_name: "#{name}/delivery:x"
             )

    assert_receive %Delta{text: "ok"}, 1_000
    SkillKit.stop_agent(agent)
  end

  test "send_event with initial_messages: :empty sends only the event user message to LLM" do
    name = "send-event-empty-#{System.unique_integer([:positive])}"

    counter = :counters.new(1, [:atomics])

    Mox.expect(SkillKit.LLM.Mock, :stream, 1, fn messages, _opts ->
      index = :counters.get(counter, 1) + 1
      :counters.put(counter, 1, index)

      assert messages == [%UserMessage{content: "pointer"}]

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

    assert_receive %Delta{text: "ok-1"}, 1_000
    SkillKit.stop_agent(agent)
  end
end
