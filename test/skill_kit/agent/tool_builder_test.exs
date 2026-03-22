defmodule SkillKit.Agent.ToolBuilderTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.Definition
  alias SkillKit.Agent.ToolBuilder
  alias SkillKit.Executor.ToolDefinition
  alias SkillKit.Kit
  alias SkillKit.Skill

  describe "build_tools/2" do
    test "includes executor tool definitions" do
      tools = ToolBuilder.build_tools([], executors: [SkillKit.Executor.Shell])

      bash = Enum.find(tools, &(&1.name == "bash"))
      assert bash != nil
      assert bash.input_schema["properties"]["command"]
    end

    test "includes activate_skill when kits have skills" do
      kits = [
        %Kit{
          name: "test",
          skills: [
            %Skill{name: "tools:echo", namespace: "tools", description: "Echo input back"},
            %Skill{name: "tools:search", namespace: "tools", description: "Search files"}
          ]
        }
      ]

      tools = ToolBuilder.build_tools(kits, executors: [SkillKit.Executor.Shell])

      activate = Enum.find(tools, &(&1.name == "activate_skill"))
      assert activate != nil
      assert activate.input_schema["properties"]["name"]
      assert "tools:echo" in activate.input_schema["properties"]["name"]["enum"]
      assert "tools:search" in activate.input_schema["properties"]["name"]["enum"]
    end

    test "does not include activate_skill when no skills" do
      tools = ToolBuilder.build_tools([], executors: [SkillKit.Executor.Shell])

      refute Enum.any?(tools, &(&1.name == "activate_skill"))
    end

    test "includes agent delegation tools" do
      kits = [
        %Kit{
          name: "test",
          agents: [
            %Definition{name: "project-a", description: "Manages project A", system_prompt: ".", path: "/tmp", workspace: "/tmp"}
          ]
        }
      ]

      tools = ToolBuilder.build_tools(kits, executors: [SkillKit.Executor.Shell])

      agent_tool = Enum.find(tools, &(&1.name == "project-a"))
      assert agent_tool != nil
      assert agent_tool.description == "Manages project A"
      assert agent_tool.input_schema["properties"]["task"]
    end

    test "includes builtins when subagent: true" do
      tools = ToolBuilder.build_tools([], executors: [SkillKit.Executor.Shell], subagent: true)

      assert Enum.any?(tools, &(&1.name == "report_status"))
      assert Enum.any?(tools, &(&1.name == "report_result"))
    end

    test "excludes builtins by default" do
      tools = ToolBuilder.build_tools([], executors: [SkillKit.Executor.Shell])

      refute Enum.any?(tools, &(&1.name == "report_status"))
      refute Enum.any?(tools, &(&1.name == "report_result"))
    end
  end

  describe "classifier/1" do
    test "returns :activate_skill for activate_skill" do
      classify = ToolBuilder.classifier([])
      assert classify.(%{name: "activate_skill"}) == :activate_skill
    end

    test "returns :subagent for agent names" do
      kits = [%Kit{
        name: "test",
        agents: [%Definition{name: "helper", description: ".", system_prompt: ".", path: "/tmp", workspace: "/tmp"}]
      }]

      classify = ToolBuilder.classifier(kits)
      assert classify.(%{name: "helper"}) == :subagent
    end

    test "returns :builtin for report_status and report_result" do
      classify = ToolBuilder.classifier([])
      assert classify.(%{name: "report_status"}) == :builtin
      assert classify.(%{name: "report_result"}) == :builtin
    end

    test "returns :executor for everything else" do
      classify = ToolBuilder.classifier([])
      assert classify.(%{name: "bash"}) == :executor
    end
  end
end
