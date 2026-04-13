defmodule SkillKit.Web.AgentsTest do
  use ExUnit.Case

  alias SkillKit.Types.UserMessage
  alias SkillKit.Web.Agents
  alias SkillKit.Web.ConversationStore

  @tmp_dir Path.expand("../../tmp/agents_test", __DIR__)

  setup do
    File.rm_rf!(@tmp_dir)
    conversations_dir = Path.join(@tmp_dir, "conversations")
    docs_dir = Path.join(@tmp_dir, "docs")
    File.mkdir_p!(conversations_dir)
    File.mkdir_p!(docs_dir)

    Application.put_env(:skill_kit_web, :project_root, @tmp_dir)
    Application.put_env(:skill_kit_web, :docs_root, docs_dir)

    on_exit(fn ->
      File.rm_rf!(@tmp_dir)
      Application.delete_env(:skill_kit_web, :project_root)
      Application.delete_env(:skill_kit_web, :docs_root)
    end)

    {:ok, conversations_dir: conversations_dir, docs_dir: docs_dir}
  end

  describe "start_assistant/1" do
    test "sends {:conversation_loaded, []} for fresh project" do
      {:ok, agent_ref} = Agents.start_assistant(self())

      assert_receive {:conversation_loaded, []}, 2000

      SkillKit.stop_agent(agent_ref)
    end

    test "sends {:conversation_loaded, messages} with existing history" do
      dir = SkillKitWeb.conversations_dir()

      messages = [
        %UserMessage{content: "hello"},
        %SkillKit.Types.AssistantMessage{content: "Hi!", tool_calls: []}
      ]

      ConversationStore.save("assistant", messages, dir: dir)

      {:ok, agent_ref} = Agents.start_assistant(self())

      assert_receive {:conversation_loaded, loaded}, 2000
      assert length(loaded) == 2

      SkillKit.stop_agent(agent_ref)
    end
  end

  describe "start_onboarding/2" do
    test "sends {:conversation_loaded, []} for new onboarding" do
      {:ok, agent_ref} = Agents.start_onboarding(self(), "onboard-test-123")

      assert_receive {:conversation_loaded, []}, 2000

      SkillKit.stop_agent(agent_ref)
    end
  end
end
