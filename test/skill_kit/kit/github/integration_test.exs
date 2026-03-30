defmodule SkillKit.Kit.GitHub.IntegrationTest do
  use ExUnit.Case, async: true

  alias SkillKit.Catalog
  alias SkillKit.Kit.GitHub

  setup do
    cache_dir =
      Path.join(
        System.tmp_dir!(),
        "skill_kit_integration_test_#{:erlang.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(cache_dir) end)

    %{cache_dir: cache_dir}
  end

  test "Catalog discovers github built-in skills", %{cache_dir: cache_dir} do
    providers = [{GitHub, [allowed_sources: "*", cache_dir: cache_dir]}]
    {:ok, catalog} = Catalog.start_link(providers: providers)

    skills = Catalog.list_skills(catalog)
    skill_names = Enum.map(skills, fn {name, _desc} -> name end)

    assert "github:import" in skill_names
    assert "github:list" in skill_names
    assert "github:remove" in skill_names
  end

  test "Catalog sees cached repo skills after import", %{cache_dir: cache_dir} do
    populate_cache(cache_dir, "owner", "repo", "main")

    providers = [{GitHub, [allowed_sources: "*", cache_dir: cache_dir]}]
    {:ok, catalog} = Catalog.start_link(providers: providers)

    skills = Catalog.list_skills(catalog)
    skill_names = Enum.map(skills, fn {name, _desc} -> name end)

    assert "test:greet" in skill_names
  end

  test "tool_definitions includes activate_skill with github skills", %{cache_dir: cache_dir} do
    providers = [{GitHub, [allowed_sources: "*", cache_dir: cache_dir]}]
    {:ok, catalog} = Catalog.start_link(providers: providers)

    tools = Catalog.tool_definitions(catalog)
    tool_names = Enum.map(tools, & &1.name)

    assert "activate_skill" in tool_names
  end

  test "classify recognizes github skills as module_skill when activated", %{
    cache_dir: cache_dir
  } do
    providers = [{GitHub, [allowed_sources: "*", cache_dir: cache_dir]}]
    {:ok, catalog} = Catalog.start_link(providers: providers)

    {:ok, skill} = Catalog.get_skill(catalog, "github:import")
    result = Catalog.classify(catalog, "import", [skill])

    assert {:module_skill, ^skill} = result
  end

  defp populate_cache(cache_dir, owner, repo, ref) do
    kit_dir = Path.join([cache_dir, owner, repo, ref])
    skill_dir = Path.join([kit_dir, "skills", "greet"])
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: "test:greet"
    description: "A greeting skill"
    ---
    Say hello to the user.
    """)
  end
end
