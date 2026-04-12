defmodule SkillKit.Test.EchoKit do
  use SkillKit.Kit,
    name: "test_kit",
    path: Path.expand("../../support/fixtures/test_kit", __DIR__)

  alias SkillKit.ToolExecution

  @impl SkillKit.Tool
  def execute(%ToolExecution{skill: %{name: "test_kit:greet"}, input: input}) do
    {:ok, "Hello, #{input["name"]}!"}
  end
end

defmodule SkillKit.Kit.ModuleBackedTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.Memory
  alias SkillKit.Skill
  alias SkillKit.Test.EchoKit
  alias SkillKit.ToolExecution

  describe "module-backed skill lifecycle" do
    setup do
      {:ok, [kit]} = EchoKit.load_kits([])
      [skill] = kit.skills

      {:ok, provider} = Memory.start_link([])
      Memory.put_kit(provider, kit)

      catalog =
        start_supervised!({SkillKit.Catalog, providers: [{Memory, provider: provider}]})

      %{kit: kit, skill: skill, catalog: catalog}
    end

    test "skill appears in activate_skill enum but not as a tool before activation", %{
      catalog: catalog
    } do
      tools = SkillKit.Catalog.tool_definitions(catalog, [])
      activate_tool = Enum.find(tools, &(&1.name == "activate_skill"))

      assert "test_kit:greet" in activate_tool.input_schema["properties"]["name"]["enum"]

      tool_names = Enum.map(tools, & &1.name)
      refute "greet" in tool_names
    end

    test "execute dispatches through Kit module", %{skill: skill} do
      execution = %ToolExecution{
        skill: skill,
        input: %{"name" => "World"},
        context: %{}
      }

      assert {:ok, "Hello, World!"} = EchoKit.execute(execution)
    end

    test "skill has correct properties", %{skill: skill} do
      assert %Skill{} = skill
      assert skill.name == "test_kit:greet"
      assert skill.namespace == "test_kit"
      assert skill.tool == SkillKit.Test.EchoKit
      assert skill.description == "Greet a user"
      assert skill.body =~ "greet"
    end
  end
end
