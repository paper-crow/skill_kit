defmodule SkillKit.Agent.DefinitionTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.Definition

  @fixtures_path Path.join([__DIR__, "..", "..", "support", "fixtures", "agents"])

  describe "parse/1" do
    test "parses a full AGENT.md with all fields" do
      path = Path.join([@fixtures_path, "valid", "project-a", "AGENT.md"])
      assert {:ok, definition} = Definition.parse(path)

      assert definition.name == "project-a"
      assert definition.description == "Manages project A. Use when the user asks about project A."
      assert definition.capabilities == ["Read", "Grep", "Glob", "Bash"]
      assert definition.model == "claude-sonnet-4-6"
      assert definition.system_prompt =~ "project A manager"
      assert definition.path == path
      assert definition.workspace =~ "project-a"
      assert definition.max_agent_depth == 2
      assert definition.mailbox.max_messages == 5
      assert definition.mailbox.flush_interval == 200
    end

    test "parses minimal AGENT.md with defaults" do
      path = Path.join([@fixtures_path, "valid", "simple", "AGENT.md"])
      assert {:ok, definition} = Definition.parse(path)

      assert definition.name == "simple"
      assert definition.description == "A simple agent with defaults."
      assert definition.capabilities == []
      assert definition.model == nil
      assert definition.system_prompt =~ "Do the thing"
      assert definition.max_agent_depth == 1
      assert definition.mailbox.max_messages == 10
      assert definition.mailbox.flush_interval == 500
    end

    test "defaults workspace to directory containing AGENT.md" do
      path = Path.join([@fixtures_path, "valid", "simple", "AGENT.md"])
      assert {:ok, definition} = Definition.parse(path)

      expected_workspace = Path.join([@fixtures_path, "valid", "simple"])
      assert definition.workspace == expected_workspace
    end

    test "returns error for missing name" do
      path = Path.join([@fixtures_path, "invalid", "missing-name", "AGENT.md"])
      assert {:error, {:missing_field, "name"}} = Definition.parse(path)
    end

    test "returns error for nonexistent file" do
      assert {:error, :enoent} = Definition.parse("/nonexistent/AGENT.md")
    end
  end
end
