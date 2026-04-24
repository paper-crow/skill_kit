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

  test "send_event runs a sub-loop and appends {UserMessage, AssistantMessage} to messages" do
    name = "send-event-#{System.unique_integer([:positive])}"
    SkillKit.Test.expect_response(%SkillKit.Response.Text{content: "delivery processed"})

    {:ok, agent} = SkillKit.start_agent(definition(name), caller: self())

    assert :ok =
             SkillKit.send_event(agent, "<webhook-delivery id=\"dlv_abc\"/>",
               system_append: "Process this webhook.",
               sub_agent_name: "#{name}/delivery:wh_1"
             )

    assert_receive %Delta{text: "delivery processed", agent: sub_name}, 1000
    assert sub_name == "#{name}/delivery:wh_1"

    # Let the Server finish appending state
    Process.sleep(50)

    state = server_state(agent)

    assert [
             %UserMessage{content: "<webhook-delivery id=\"dlv_abc\"/>"},
             %AssistantMessage{content: "delivery processed"}
           ] = state.messages

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

    SkillKit.Test.assert_response(
      %SkillKit.Response.Text{content: "ok"},
      fn _messages, opts ->
        system = Keyword.fetch!(opts, :system)
        assert system == "You are helpful.\n\nHandle this webhook event."
      end
    )

    {:ok, agent} = SkillKit.start_agent(definition(name), caller: self())

    assert :ok =
             SkillKit.send_event(agent, "pointer",
               system_append: "Handle this webhook event.",
               sub_agent_name: "#{name}/delivery:x"
             )

    assert_receive %Delta{text: "ok"}, 1000
    SkillKit.stop_agent(agent)
  end

  test "send_event with initial_messages: :empty sends only the event user message to LLM" do
    name = "send-event-empty-#{System.unique_integer([:positive])}"

    SkillKit.Test.assert_response(
      %SkillKit.Response.Text{content: "ok"},
      fn messages, _opts ->
        assert messages == [%UserMessage{content: "pointer"}]
      end
    )

    {:ok, agent} = SkillKit.start_agent(definition(name), caller: self())

    assert :ok =
             SkillKit.send_event(agent, "pointer",
               system_append: "Intent.",
               initial_messages: :empty,
               sub_agent_name: "#{name}/delivery:x"
             )

    assert_receive %Delta{text: "ok"}, 1000
    SkillKit.stop_agent(agent)
  end
end
