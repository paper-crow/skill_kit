defmodule SkillKit.AgentTest do
  use ExUnit.Case, async: true

  @fixtures_path Path.join([__DIR__, "..", "..", "support", "fixtures", "agents"])

  describe "struct defaults" do
    test "new fields have correct defaults" do
      agent = %SkillKit.Agent{
        name: "test",
        description: "Test",
        system_prompt: "Test"
      }

      assert agent.skills == []
      assert agent.runtime == {SkillKit.Runtime.Local, []}
      assert agent.scope == nil
      assert agent.conversation_store == nil
      assert agent.caller == nil
      assert agent.parent_ref == nil
      assert agent.registry == nil
      assert agent.depth == 0
    end

    test "parse/1 returns agent with new fields defaulted" do
      path = Path.join([@fixtures_path, "valid", "simple", "AGENT.md"])
      content = File.read!(path)
      assert {:ok, agent} = SkillKit.Agent.parse(content)

      assert agent.skills == []
      assert agent.runtime == {SkillKit.Runtime.Local, []}
      assert agent.scope == nil
      assert agent.depth == 0
    end
  end

  describe "parse/1" do
    test "parses a full AGENT.md with all fields" do
      content = File.read!(Path.join([@fixtures_path, "valid", "project-a", "AGENT.md"]))
      assert {:ok, agent} = SkillKit.Agent.parse(content)

      assert agent.name == "project-a"

      assert agent.description ==
               "Manages project A. Use when the user asks about project A."

      assert agent.model == "claude-sonnet-4-6"
      assert agent.system_prompt =~ "project A manager"
      assert agent.max_agent_depth == 2
      assert agent.mailbox.max_messages == 5
      assert agent.mailbox.flush_interval == 200
    end

    test "parses minimal AGENT.md with defaults" do
      content = File.read!(Path.join([@fixtures_path, "valid", "simple", "AGENT.md"]))
      assert {:ok, agent} = SkillKit.Agent.parse(content)

      assert agent.name == "simple"
      assert agent.description == "A simple agent with defaults."
      assert agent.model == nil
      assert agent.system_prompt =~ "Do the thing"
      assert agent.max_agent_depth == 1
      assert agent.mailbox.max_messages == 10
      assert agent.mailbox.flush_interval == 500
    end

    test "returns error for missing name" do
      content = File.read!(Path.join([@fixtures_path, "invalid", "missing-name", "AGENT.md"]))
      assert {:error, {:missing_field, "name"}} = SkillKit.Agent.parse(content)
    end
  end
end
