defmodule SkillKit.Eval.SkillFileTest do
  use ExUnit.Case, async: false

  alias SkillKit.Eval.SkillFile
  alias SkillKit.Kit
  alias SkillKit.Skill
  alias SkillKit.Storage

  @disk Path.expand("../../support/fixtures/colocated_skill/SKILL.md", __DIR__)
  @path "skill_file_test/SKILL.md"

  setup do
    start_supervised!(Storage.Memory)
    Storage.put!(@path, File.read!(@disk))
    :ok
  end

  test "loads a single SKILL.md into a one-skill kit" do
    assert {:ok, [%Kit{skills: [%Skill{} = skill]}]} = SkillFile.load_kits(path: @path)
    assert skill.name == "greeter"
    assert skill.body =~ "address the user by their name"
  end

  test "list_kits mirrors load_kits" do
    assert SkillFile.list_kits(path: @path) == SkillFile.load_kits(path: @path)
  end

  test "propagates read errors for a missing file" do
    assert {:error, _reason} = SkillFile.load_kits(path: "nope/SKILL.md")
  end
end
