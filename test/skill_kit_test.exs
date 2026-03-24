defmodule SkillKitTest do
  use ExUnit.Case

  import Mox

  alias SkillKit.Conversation.Store.Filesystem
  alias SkillKit.Event.Delta
  alias SkillKit.Types.AssistantMessage

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
        model: "test-model"
      }

      SkillKit.Test.expect_response(%SkillKit.Response.Text{content: "Hello world"})

      {:ok, agent} =
        SkillKit.start_agent(definition,
          caller: self()
        )

      assert %SkillKit.AgentRef{name: "api-test-agent"} = agent

      assert {:ok, %AssistantMessage{content: "Hello world"}} =
               SkillKit.send_message_sync(agent, "Hi")

      assert_receive %Delta{text: "Hello world"}

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

      {:ok, agent} = SkillKit.start_agent(definition)
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

      {:ok, agent} = SkillKit.start_agent(definition)
      assert Process.whereis(agent.registry) != nil

      SkillKit.stop_agent(agent)
      Process.sleep(50)

      assert Process.whereis(agent.registry) == nil
    end

    test "conversation_store persists and restores messages" do
      store_path =
        Path.join(
          System.tmp_dir!(),
          "skill_kit_store_test_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(store_path)
      on_exit(fn -> File.rm_rf!(store_path) end)

      store = {SkillKit.Conversation.Store.Filesystem, path: store_path}

      definition = %SkillKit.Agent.Definition{
        name: "store-test-agent",
        description: "Test",
        system_prompt: "Test",
        path: "/tmp/test",
        workspace: "/tmp/test",
        model: "test-model"
      }

      # First session — agent gets a message and responds
      SkillKit.Test.expect_response(%SkillKit.Response.Text{content: "Hi!"})

      {:ok, agent} =
        SkillKit.start_agent(definition,
          conversation_store: store,
          caller: self()
        )

      assert {:ok, %AssistantMessage{content: "Hi!"}} =
               SkillKit.send_message_sync(agent, "Hello")

      # Give the Server time to complete save_conversation after the turn
      Process.sleep(100)
      SkillKit.stop_agent(agent)
      Process.sleep(50)

      # Verify file was written
      assert {:ok, messages} =
               Filesystem.load("store-test-agent", path: store_path)

      assert length(messages) == 2
    end
  end

  describe "send_message_sync/3" do
    test "blocks and returns {:ok, %AssistantMessage{}} for text response" do
      definition = %SkillKit.Agent.Definition{
        name: "sync-test-agent",
        description: "Test",
        system_prompt: "Test",
        path: "/tmp/test",
        workspace: "/tmp/test",
        model: "test-model"
      }

      SkillKit.Test.expect_response(%SkillKit.Response.Text{content: "Hello world"})

      {:ok, agent} = SkillKit.start_agent(definition, caller: self())

      assert {:ok, %AssistantMessage{content: "Hello world"}} =
               SkillKit.send_message_sync(agent, "Hi")
    end

    test "returns {:error, reason} for LLM errors" do
      definition = %SkillKit.Agent.Definition{
        name: "sync-error-agent",
        description: "Test",
        system_prompt: "Test",
        path: "/tmp/test",
        workspace: "/tmp/test"
      }

      SkillKit.Test.expect_error(500, "internal error")

      {:ok, agent} = SkillKit.start_agent(definition, caller: self())

      assert {:error, {500, "internal error"}} = SkillKit.send_message_sync(agent, "Hi")
    end

    test "deltas arrive at caller before send_message_sync returns" do
      definition = %SkillKit.Agent.Definition{
        name: "sync-delta-agent",
        description: "Test",
        system_prompt: "Test",
        path: "/tmp/test",
        workspace: "/tmp/test",
        model: "test-model"
      }

      SkillKit.Test.expect_response(%SkillKit.Response.Text{content: "Hello world"})

      {:ok, agent} = SkillKit.start_agent(definition, caller: self())

      {:ok, %AssistantMessage{content: "Hello world"}} =
        SkillKit.send_message_sync(agent, "Hi")

      # Deltas should be in the mailbox — they arrived before the response
      assert_receive %Delta{text: "Hello world"}
    end

    test "returns {:error, :timeout} when timeout expires" do
      definition = %SkillKit.Agent.Definition{
        name: "sync-timeout-agent",
        description: "Test",
        system_prompt: "Test",
        path: "/tmp/test",
        workspace: "/tmp/test"
      }

      # Mock that never returns — simulate a halted server
      Mox.stub(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
        Process.sleep(:infinity)
      end)

      {:ok, agent} = SkillKit.start_agent(definition, caller: self())

      assert {:error, :timeout} = SkillKit.send_message_sync(agent, "Hi", 100)
    end
  end
end
