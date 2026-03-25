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
  @nested_fixtures_path Path.join([
                          __DIR__,
                          "..",
                          "..",
                          "support",
                          "fixtures",
                          "skills",
                          "nested"
                        ])
  @fixtures_root Path.join([__DIR__, "..", "..", "support", "fixtures", "skills"])
  @root_agent_fixtures_path Path.join([
                              __DIR__,
                              "..",
                              "..",
                              "support",
                              "fixtures",
                              "skills",
                              "with_root_agent"
                            ])

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

  describe "load_kits/1 with dir: (singular)" do
    test "loads skills and agents from a single directory" do
      assert {:ok, [kit]} = Filesystem.load_kits(dir: @root_agent_fixtures_path)
      skill_names = Enum.map(kit.skills, & &1.name)
      assert Enum.any?(skill_names, &String.contains?(&1, "test"))
    end

    test "detects root AGENT.md as root_agent" do
      assert {:ok, [kit]} = Filesystem.load_kits(dir: @root_agent_fixtures_path)
      assert kit.root_agent != nil
      assert kit.root_agent.name == "root-agent"
    end

    test "nested agents go into agents list, not root_agent" do
      assert {:ok, [kit]} = Filesystem.load_kits(dir: @root_agent_fixtures_path)
      agent_names = Enum.map(kit.agents, & &1.name)
      assert "helper" in agent_names
      assert "deep-nested" in agent_names
      refute "root-agent" in agent_names
    end

    test "skills are loaded alongside root agent" do
      assert {:ok, [kit]} = Filesystem.load_kits(dir: @root_agent_fixtures_path)
      skill_names = Enum.map(kit.skills, & &1.name)
      assert Enum.any?(skill_names, &String.contains?(&1, "test"))
    end

    test "kit with no root AGENT.md has nil root_agent" do
      assert {:ok, [kit]} = Filesystem.load_kits(dir: @valid_fixtures_path)
      assert is_nil(kit.root_agent)
    end

    test "returns {:ok, []} for nonexistent directory" do
      assert {:ok, []} = Filesystem.load_kits(dir: "/nonexistent/path")
    end
  end
end
