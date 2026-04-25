defmodule SkillKit.Tools.SendMessageTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.AgentRef
  alias SkillKit.Event.Delta
  alias SkillKit.Storage
  alias SkillKit.ToolExecution
  alias SkillKit.Tools.SendMessage

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

  describe "definition/0" do
    test "returns a valid Tool struct" do
      assert SendMessage.definition() == %SkillKit.Tool{
               name: "send_message",
               description:
                 "Send a message to the bound target agent. The target is configured at " <>
                   "tool registration time; you only supply the content. Use this when you " <>
                   "want the receiving agent to wake and process what you have to say.",
               input_schema: %{
                 "type" => "object",
                 "properties" => %{
                   "content" => %{
                     "type" => "string",
                     "description" => "The message content to deliver to the target agent."
                   }
                 },
                 "required" => ["content"]
               }
             }
    end
  end

  describe "execute/1" do
    test "casts content to the target agent's mailbox and returns success" do
      name = "send-message-target-#{System.unique_integer([:positive])}"

      SkillKit.Test.expect_responses([
        %SkillKit.Response.Text{content: "ack"}
      ])

      {:ok, agent} = SkillKit.start_agent(definition(name), caller: self())

      execution = %ToolExecution{
        tool: SendMessage,
        input: %{"content" => "hello main agent"},
        context: %{target: agent}
      }

      assert {:ok, "Message sent."} = SendMessage.execute(execution)

      assert_receive %Delta{text: "ack", agent: ^name}, 1_000

      SkillKit.stop_agent(agent)
    end

    test "execute/1 with a target ref pointing at a different agent delivers there" do
      sender_name = "send-message-sender-#{System.unique_integer([:positive])}"
      target_name = "send-message-recipient-#{System.unique_integer([:positive])}"

      # Only the target agent runs an LLM turn. The sender is started just to
      # demonstrate the cross-agent shape — the tool is invoked directly via
      # SendMessage.execute/1 from the test process, not through the sender.
      SkillKit.Test.expect_responses([
        %SkillKit.Response.Text{content: "received"}
      ])

      {:ok, sender} = SkillKit.start_agent(definition(sender_name))
      {:ok, target} = SkillKit.start_agent(definition(target_name), caller: self())

      execution = %ToolExecution{
        tool: SendMessage,
        input: %{"content" => "hello recipient"},
        context: %{target: target}
      }

      assert {:ok, "Message sent."} = SendMessage.execute(execution)

      assert_receive %Delta{text: "received", agent: ^target_name}, 1_000

      SkillKit.stop_agent(sender)
      SkillKit.stop_agent(target)
    end

    test "returns error when target agent is not running" do
      name = "send-message-dead-#{System.unique_integer([:positive])}"

      {:ok, agent} = SkillKit.start_agent(definition(name))
      SkillKit.stop_agent(agent)
      Process.sleep(50)

      execution = %ToolExecution{
        tool: SendMessage,
        input: %{"content" => "hello"},
        context: %{target: agent}
      }

      assert {:error, "Target agent is not running."} = SendMessage.execute(execution)
    end

    test "returns error when content is missing from input" do
      execution = %ToolExecution{
        tool: SendMessage,
        input: %{},
        context: %{target: %AgentRef{name: "x", registry: :x, supervisor_pid: nil}}
      }

      assert {:error, "Missing required field: content" <> _} = SendMessage.execute(execution)
    end
  end

  describe "resume/3" do
    test "returns an error — suspension is not supported" do
      assert {:error, _} = SendMessage.resume(%ToolExecution{}, nil, nil)
    end
  end
end
