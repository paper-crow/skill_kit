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

  describe "load_kits/1" do
    test "loads valid .skill.md files from directories" do
      assert {:ok, kits} = Filesystem.load_kits(dirs: [@valid_fixtures_path])
      skills = Enum.flat_map(kits, & &1.skills)
      skill_names = Enum.map(skills, & &1.name)

      assert "files:summarize" in skill_names
      assert "tools:greet" in skill_names
    end

    test "recursively discovers .skill.md files in subdirectories" do
      assert {:ok, kits} = Filesystem.load_kits(dirs: [@nested_fixtures_path])
      skills = Enum.flat_map(kits, & &1.skills)
      skill_names = Enum.map(skills, & &1.name)

      assert "admin:delete-user" in skill_names
    end

    test "skips malformed files with warning and returns valid ones" do
      log =
        capture_log([level: :warning], fn ->
          assert {:ok, kits} = Filesystem.load_kits(dirs: [@invalid_fixtures_path])
          assert is_list(kits)
        end)

      assert log =~ "SkillKit"
      assert log =~ "skipped"
    end

    test "ignores files without .skill.md extension" do
      assert {:ok, kits} = Filesystem.load_kits(dirs: [@fixtures_root])
      skills = Enum.flat_map(kits, & &1.skills)
      skill_names = Enum.map(skills, & &1.name)

      refute "should:ignore" in skill_names
    end

    test "returns {:ok, []} for empty dirs list" do
      assert {:ok, []} = Filesystem.load_kits(dirs: [])
    end

    test "returns {:ok, []} for nonexistent directory" do
      assert {:ok, kits} = Filesystem.load_kits(dirs: ["/nonexistent/path"])
      assert kits == []
    end
  end
end
