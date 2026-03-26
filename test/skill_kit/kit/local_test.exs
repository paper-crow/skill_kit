defmodule SkillKit.Kit.LocalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SkillKit.Kit.Local

  @valid_kit Path.join([__DIR__, "..", "..", "support", "fixtures", "skills", "valid"])
  @invalid_kit Path.join([__DIR__, "..", "..", "support", "fixtures", "skills", "invalid"])
  @nested_kit Path.join([__DIR__, "..", "..", "support", "fixtures", "skills", "nested"])
  @root_agent_kit Path.join([
                    __DIR__,
                    "..",
                    "..",
                    "support",
                    "fixtures",
                    "skills",
                    "with_root_agent"
                  ])
  @wildcard_dir Path.join([__DIR__, "..", "..", "support", "fixtures", "skills", "wildcard"])

  describe "load_kits/1 with dir: (single kit)" do
    test "loads skills from skills/*/SKILL.md directories" do
      assert {:ok, [kit]} = Local.load_kits(dir: @valid_kit)
      skill_names = Enum.map(kit.skills, & &1.name)

      assert "files:summarize" in skill_names
      assert "tools:greet" in skill_names
    end

    test "does not recurse into skill subdirectories" do
      assert {:ok, [kit]} = Local.load_kits(dir: @nested_kit)
      skill_names = Enum.map(kit.skills, & &1.name)

      assert "admin:delete-user" in skill_names
      assert length(kit.skills) == 1
    end

    test "detects root AGENT.md as root_agent" do
      assert {:ok, [kit]} = Local.load_kits(dir: @root_agent_kit)
      assert kit.root_agent != nil
      assert kit.root_agent.name == "root-agent"
    end

    test "loads agents from agents/*.md" do
      assert {:ok, [kit]} = Local.load_kits(dir: @root_agent_kit)
      agent_names = Enum.map(kit.agents, & &1.name)

      assert "helper" in agent_names
      refute "root-agent" in agent_names
    end

    test "skips non-skill subdirectories inside skills/ silently" do
      assert {:ok, [kit]} = Local.load_kits(dir: @valid_kit)
      assert length(kit.skills) == 3
    end

    test "skips malformed skill files with warning" do
      log =
        capture_log([level: :warning], fn ->
          assert {:ok, [kit]} = Local.load_kits(dir: @invalid_kit)
          assert is_list(kit.skills)
        end)

      assert log =~ "SkillKit"
      assert log =~ "skipped"
    end

    test "kit with no root AGENT.md has nil root_agent" do
      assert {:ok, [kit]} = Local.load_kits(dir: @valid_kit)
      assert is_nil(kit.root_agent)
    end

    test "returns {:ok, []} for nonexistent directory" do
      assert {:ok, []} = Local.load_kits(dir: "/nonexistent/path")
    end

    test "returns error for explicit dir that is not a valid kit" do
      empty_dir =
        Path.join(System.tmp_dir!(), "empty_kit_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(empty_dir)
      on_exit(fn -> File.rm_rf!(empty_dir) end)

      assert {:error, :invalid_kit} = Local.load_kits(dir: empty_dir)
    end
  end

  describe "load_kits/1 with dir: wildcard" do
    test "loads each immediate child as a separate kit" do
      assert {:ok, kits} = Local.load_kits(dir: "#{@wildcard_dir}/*")
      kit_names = Enum.map(kits, & &1.name)

      assert "kit-a" in kit_names
      assert "kit-b" in kit_names
    end

    test "skips hidden directories silently" do
      assert {:ok, kits} = Local.load_kits(dir: "#{@wildcard_dir}/*")
      kit_names = Enum.map(kits, & &1.name)

      refute ".hidden-kit" in kit_names
    end

    test "warns and skips non-kit directories" do
      log =
        capture_log([level: :warning], fn ->
          assert {:ok, kits} = Local.load_kits(dir: "#{@wildcard_dir}/*")
          kit_names = Enum.map(kits, & &1.name)

          refute "not-a-kit" in kit_names
        end)

      assert log =~ "not-a-kit"
    end

    test "each kit has its own skills" do
      assert {:ok, kits} = Local.load_kits(dir: "#{@wildcard_dir}/*")

      kit_a = Enum.find(kits, &(&1.name == "kit-a"))
      kit_b = Enum.find(kits, &(&1.name == "kit-b"))

      assert Enum.any?(kit_a.skills, &(&1.name == "kit-a:alpha"))
      assert Enum.any?(kit_b.skills, &(&1.name == "kit-b:beta"))
    end
  end
end
