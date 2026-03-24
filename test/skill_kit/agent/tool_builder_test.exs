defmodule SkillKit.Agent.ToolBuilderTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.Definition
  alias SkillKit.Agent.ToolBuilder
  alias SkillKit.Kit
  alias SkillKit.Skill

  describe "build_tools/2" do
    test "includes handler tool definitions" do
      tools = ToolBuilder.build_tools([], handlers: [SkillKit.Handler.Shell])

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

      tools = ToolBuilder.build_tools(kits, handlers: [SkillKit.Handler.Shell])

      activate = Enum.find(tools, &(&1.name == "activate_skill"))
      assert activate != nil
      assert activate.input_schema["properties"]["name"]
      assert "tools:echo" in activate.input_schema["properties"]["name"]["enum"]
      assert "tools:search" in activate.input_schema["properties"]["name"]["enum"]
    end

    test "does not include activate_skill when no skills" do
      tools = ToolBuilder.build_tools([], handlers: [SkillKit.Handler.Shell])

      refute Enum.any?(tools, &(&1.name == "activate_skill"))
    end

    test "includes agent delegation tools" do
      kits = [
        %Kit{
          name: "test",
          agents: [
            %Definition{
              name: "project-a",
              description: "Manages project A",
              system_prompt: ".",
              path: "/tmp",
              workspace: "/tmp"
            }
          ]
        }
      ]

      tools = ToolBuilder.build_tools(kits, handlers: [SkillKit.Handler.Shell])

      agent_tool = Enum.find(tools, &(&1.name == "project-a"))
      assert agent_tool != nil
      assert agent_tool.description == "Manages project A"
      assert agent_tool.input_schema["properties"]["task"]
    end

    test "includes builtins when subagent: true" do
      tools = ToolBuilder.build_tools([], handlers: [SkillKit.Handler.Shell], subagent: true)

      assert Enum.any?(tools, &(&1.name == "report_status"))
      assert Enum.any?(tools, &(&1.name == "report_result"))
    end

    test "excludes builtins by default" do
      tools = ToolBuilder.build_tools([], handlers: [SkillKit.Handler.Shell])

      refute Enum.any?(tools, &(&1.name == "report_status"))
      refute Enum.any?(tools, &(&1.name == "report_result"))
    end

    test "activated module-backed skills appear as individual tools" do
      module_skill = %Skill{
        name: "scheduler:schedule",
        namespace: "scheduler",
        description: "Schedule a task",
        body: "Use schedule tool",
        handler: SkillKit.Handler.Shell
      }

      tools = ToolBuilder.build_tools([], activated_skills: [module_skill])
      tool_names = Enum.map(tools, & &1.name)
      assert "schedule" in tool_names
    end

    test "activated skills with unloadable handlers are excluded" do
      bad_skill = %Skill{
        name: "broken:thing",
        namespace: "broken",
        description: "Won't load",
        body: "nope",
        handler: DoesNotExist.Module
      }

      tools = ToolBuilder.build_tools([], activated_skills: [bad_skill])
      tool_names = Enum.map(tools, & &1.name)
      refute "thing" in tool_names
    end
  end

  describe "classifier/1" do
    test "returns :activate_skill for activate_skill" do
      classify = ToolBuilder.classifier([])
      assert classify.(%{name: "activate_skill"}) == :activate_skill
    end

    test "returns :subagent for agent names" do
      kits = [
        %Kit{
          name: "test",
          agents: [
            %Definition{
              name: "helper",
              description: ".",
              system_prompt: ".",
              path: "/tmp",
              workspace: "/tmp"
            }
          ]
        }
      ]

      classify = ToolBuilder.classifier(kits)
      assert classify.(%{name: "helper"}) == :subagent
    end

    test "returns :builtin for report_status and report_result" do
      classify = ToolBuilder.classifier([])
      assert classify.(%{name: "report_status"}) == :builtin
      assert classify.(%{name: "report_result"}) == :builtin
    end

    test "returns :handler for everything else" do
      classify = ToolBuilder.classifier([])
      assert classify.(%{name: "bash"}) == :handler
    end

    test "classifier returns {:module_skill, skill} for activated module-backed skills" do
      module_skill = %Skill{
        name: "scheduler:schedule",
        namespace: "scheduler",
        description: "Schedule a task",
        body: "Use schedule tool",
        handler: SkillKit.Handler.Shell
      }

      classify = ToolBuilder.classifier([], [module_skill])
      assert {:module_skill, ^module_skill} = classify.(%{name: "schedule"})
    end

    test "classifier still returns :handler for unknown tools" do
      classify = ToolBuilder.classifier([], [])
      assert :handler = classify.(%{name: "bash"})
    end
  end
end
