defmodule SkillKit.Test.EchoKit do
  use SkillKit.Kit,
    name: "test_kit",
    skills_dir: Path.join([__DIR__, "../../support/fixtures/test_kit/skills"])

  alias SkillKit.Execution

  @impl SkillKit.Handler.Behaviour
  def execute(%Execution{skill: %{name: "test_kit:greet"}, input: input}) do
    {:ok, "Hello, #{input["name"]}!"}
  end
end

defmodule SkillKit.Kit.ModuleBackedTest do
  use ExUnit.Case, async: true

  alias SkillKit.Agent.ToolBuilder
  alias SkillKit.Execution
  alias SkillKit.Skill

  describe "module-backed skill lifecycle" do
    setup do
      {:ok, [kit]} = SkillKit.Test.EchoKit.load_kits([])
      [skill] = kit.skills
      %{kit: kit, skill: skill}
    end

    test "skill appears in activate_skill enum but not as a tool before activation", %{kit: kit} do
      tools = ToolBuilder.build_tools([kit])
      activate_tool = Enum.find(tools, &(&1.name == "activate_skill"))

      assert "test_kit:greet" in activate_tool.input_schema["properties"]["name"]["enum"]

      tool_names = Enum.map(tools, & &1.name)
      refute "greet" in tool_names
    end

    test "after activation, skill's tool appears in tool list", %{kit: kit, skill: skill} do
      tools = ToolBuilder.build_tools([kit], activated_skills: [skill])
      tool_names = Enum.map(tools, & &1.name)
      assert "greet" in tool_names
    end

    test "classifier routes activated skill to {:module_skill, skill}", %{kit: kit, skill: skill} do
      classify = ToolBuilder.classifier([kit], [skill])
      assert {:module_skill, ^skill} = classify.(%{name: "greet"})
    end

    test "execute dispatches through Kit module", %{skill: skill} do
      execution = %Execution{
        skill: skill,
        input: %{"name" => "World"},
        context: %{}
      }

      assert {:ok, "Hello, World!"} = SkillKit.Test.EchoKit.execute(execution)
    end

    test "skill has correct properties", %{skill: skill} do
      assert %Skill{} = skill
      assert skill.name == "test_kit:greet"
      assert skill.namespace == "test_kit"
      assert skill.handler == SkillKit.Test.EchoKit
      assert skill.description == "Greet a user"
      assert skill.body =~ "greet"
    end
  end
end
