defmodule SkillKitTest do
  use ExUnit.Case

  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  describe "start_agent/2 + send_message/2 + stop_agent/1" do
    test "full lifecycle with streaming deltas" do
      definition = %SkillKit.Agent.Definition{
        name: "api-test-agent",
        description: "Test agent",
        system_prompt: "You are helpful.",
        path: "/tmp/test",
        workspace: "/tmp/test",
        model: "test-model",
        max_tokens: 1024
      }

      expect(SkillKit.LLM.Mock, :stream, fn _config, _messages, _opts ->
        events = [
          %{"type" => "message_start", "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}},
          %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
          %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hello"}},
          %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => " world"}},
          %{"type" => "content_block_stop", "index" => 0},
          %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}},
          %{"type" => "message_stop"}
        ]
        {:ok, Stream.map(events, & &1)}
      end)

      {:ok, agent} = SkillKit.start_agent(definition,
        provider: {SkillKit.LLM.Mock, []},
        caller: self()
      )

      assert %SkillKit.AgentRef{name: "api-test-agent"} = agent

      :ok = SkillKit.send_message(agent, "Hi")

      assert_receive {:skill_kit, "api-test-agent", {:delta, "Hello"}}, 2000
      assert_receive {:skill_kit, "api-test-agent", {:delta, " world"}}, 2000
      assert_receive {:skill_kit, "api-test-agent", {:response, "Hello world"}}, 2000

      assert :ok = SkillKit.stop_agent(agent)
    end

    test "send_message returns {:error, :not_found} for stopped agent" do
      definition = %SkillKit.Agent.Definition{
        name: "dead-agent",
        description: "Test",
        system_prompt: "Test",
        path: "/tmp/test",
        workspace: "/tmp/test"
      }

      {:ok, agent} = SkillKit.start_agent(definition, provider: {SkillKit.LLM.Mock, []})
      SkillKit.stop_agent(agent)
      Process.sleep(50)

      assert {:error, :not_found} = SkillKit.send_message(agent, "hello")
    end

    test "stop_agent cleans up registry" do
      definition = %SkillKit.Agent.Definition{
        name: "cleanup-agent",
        description: "Test",
        system_prompt: "Test",
        path: "/tmp/test",
        workspace: "/tmp/test"
      }

      {:ok, agent} = SkillKit.start_agent(definition, provider: {SkillKit.LLM.Mock, []})
      assert Process.whereis(agent.registry) != nil

      SkillKit.stop_agent(agent)
      Process.sleep(50)

      assert Process.whereis(agent.registry) == nil
    end
  end
end
