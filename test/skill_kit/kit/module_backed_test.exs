defmodule SkillKit.Test.EchoKit do
  use SkillKit.Kit,
    name: "test_kit",
    skills_dir: Path.join([__DIR__, "../../support/fixtures/test_kit/skills"])

  alias SkillKit.ToolExecution

  @impl SkillKit.Tool
  def execute(%ToolExecution{skill: %{name: "test_kit:greet"}, input: input}) do
    {:ok, "Hello, #{input["name"]}!"}
  end
end

defmodule SkillKit.Kit.ModuleBackedTest do
  use ExUnit.Case, async: false

  alias SkillKit.Kit.Memory
  alias SkillKit.Skill
  alias SkillKit.Storage
  alias SkillKit.Test.EchoKit
  alias SkillKit.ToolExecution

  @fixtures_disk Path.expand("../../support/fixtures/test_kit/skills", __DIR__)
  @fixtures_storage Path.join([__DIR__, "..", "..", "support", "fixtures", "test_kit", "skills"])

  describe "module-backed skill lifecycle" do
    setup do
      start_supervised!(Storage.Memory)
      seed_fixture_tree(@fixtures_disk, @fixtures_storage)

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

    test "after activation, skill's tool appears in tool list", %{
      catalog: catalog,
      skill: skill
    } do
      tools = SkillKit.Catalog.tool_definitions(catalog, activated_skills: [skill])
      tool_names = Enum.map(tools, & &1.name)
      assert "greet" in tool_names
    end

    test "classifier routes activated skill to {:module_skill, skill}", %{
      catalog: catalog,
      skill: skill
    } do
      assert {:module_skill, ^skill} =
               SkillKit.Catalog.classify(catalog, "greet", [skill])
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

  defp seed_fixture_tree(disk_path, storage_path) do
    Storage.ensure_dir!(storage_path)

    case File.ls(disk_path) do
      {:ok, entries} -> Enum.each(entries, &seed_entry(disk_path, storage_path, &1))
      {:error, _} -> :ok
    end
  end

  defp seed_entry(disk_path, storage_path, entry) do
    disk_entry = Path.join(disk_path, entry)
    storage_entry = Path.join(storage_path, entry)

    if File.dir?(disk_entry) do
      seed_fixture_tree(disk_entry, storage_entry)
    else
      {:ok, content} = File.read(disk_entry)
      Storage.put!(storage_entry, content)
    end
  end
end
