defmodule SkillKit.Web.DocumentKit.DocumentKitTest do
  use ExUnit.Case, async: true

  alias SkillKit.Web.DocumentKit

  test "list_kits returns a kit with document skills" do
    {:ok, [kit]} = DocumentKit.list_kits([])

    assert kit.name == "docs"
    assert length(kit.skills) == 8

    skill_names = Enum.map(kit.skills, & &1.name)
    assert "docs:create" in skill_names
    assert "docs:read" in skill_names
    assert "docs:update" in skill_names
    assert "docs:list" in skill_names
    assert "docs:search" in skill_names
    assert "docs:structure" in skill_names
    assert "docs:history" in skill_names
  end

  test "all skills have descriptions" do
    {:ok, [kit]} = DocumentKit.list_kits([])

    for skill <- kit.skills do
      assert skill.description != nil, "#{skill.name} has no description"
      assert skill.description != "", "#{skill.name} has empty description"
    end
  end

  test "all skills use DocumentKit.Tool as their tool" do
    {:ok, [kit]} = DocumentKit.list_kits([])

    for skill <- kit.skills do
      assert skill.tool == SkillKit.Web.DocumentKit,
             "#{skill.name} uses #{inspect(skill.tool)} instead of DocumentKit"
    end
  end
end
