defmodule SkillKit.Backend.FilesystemTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SkillKit.Backend.Filesystem

  @valid_fixtures_path Path.join([__DIR__, "..", "..", "support", "fixtures", "skills", "valid"])
  @invalid_fixtures_path Path.join([
                           __DIR__,
                           "..",
                           "..",
                           "support",
                           "fixtures",
                           "skills",
                           "invalid"
                         ])
  @nested_fixtures_path Path.join([__DIR__, "..", "..", "support", "fixtures", "skills", "nested"])
  @fixtures_root Path.join([__DIR__, "..", "..", "support", "fixtures", "skills"])

  describe "load_skills/1" do
    test "loads valid .skill.md files from directories" do
      assert {:ok, skills} = Filesystem.load_skills(dirs: [@valid_fixtures_path])
      skill_names = Enum.map(skills, & &1.name)

      assert "files:summarize" in skill_names
      assert "tools:greet" in skill_names
    end

    test "recursively discovers .skill.md files in subdirectories" do
      assert {:ok, skills} = Filesystem.load_skills(dirs: [@nested_fixtures_path])
      skill_names = Enum.map(skills, & &1.name)

      assert "admin:delete-user" in skill_names
    end

    test "skips malformed files with warning and returns valid ones" do
      log =
        capture_log([level: :warning], fn ->
          assert {:ok, skills} = Filesystem.load_skills(dirs: [@invalid_fixtures_path])
          assert is_list(skills)
        end)

      assert log =~ "SkillKit"
      assert log =~ "skipped"
    end

    test "ignores files without .skill.md extension" do
      assert {:ok, skills} = Filesystem.load_skills(dirs: [@fixtures_root])
      skill_names = Enum.map(skills, & &1.name)

      refute "should:ignore" in skill_names
    end

    test "returns {:ok, []} for empty dirs list" do
      assert {:ok, []} = Filesystem.load_skills(dirs: [])
    end

    test "returns {:ok, []} for nonexistent directory" do
      assert {:ok, []} = Filesystem.load_skills(dirs: ["/nonexistent/path"])
    end
  end
end
