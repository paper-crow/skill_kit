defmodule SkillKit.Kit.GitHub.IntegrationTest do
  use ExUnit.Case, async: false

  alias SkillKit.Catalog
  alias SkillKit.Kit.GitHub
  alias SkillKit.Storage

  setup do
    start_supervised!(Storage.Memory)

    cache_dir = "/skill_kit_integration_test_#{:erlang.unique_integer([:positive])}"

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

  test "classify recognizes activate_skill tool", %{cache_dir: cache_dir} do
    providers = [{GitHub, [allowed_sources: "*", cache_dir: cache_dir]}]
    {:ok, catalog} = Catalog.start_link(providers: providers)

    assert :activate_skill = Catalog.classify(catalog, "activate_skill")
  end

  defp populate_cache(cache_dir, owner, repo, ref) do
    kit_dir = Path.join([cache_dir, owner, repo, ref])
    skill_dir = Path.join([kit_dir, "skills", "greet"])
    Storage.ensure_dir!(skill_dir)

    Storage.put!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: "test:greet"
    description: "A greeting skill"
    ---
    Say hello to the user.
    """)
  end
end
