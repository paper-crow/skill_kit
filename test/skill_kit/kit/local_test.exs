defmodule SkillKit.Kit.LocalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SkillKit.Kit.Local
  alias SkillKit.Storage

  @fixtures_base Path.join([__DIR__, "..", "..", "support", "fixtures", "skills"])

  setup do
    start_supervised!(Storage.Memory)
    :ok
  end

  defp seed_fixture_tree(disk_path, storage_path) do
    Storage.ensure_dir!(storage_path)

    case File.ls(disk_path) do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          disk_entry = Path.join(disk_path, entry)
          storage_entry = Path.join(storage_path, entry)

          if File.dir?(disk_entry) do
            seed_fixture_tree(disk_entry, storage_entry)
          else
            {:ok, content} = File.read(disk_entry)
            Storage.put!(storage_entry, content)
          end
        end)

      {:error, _} ->
        :ok
    end
  end

  describe "load_kits/1 with dir: (single kit)" do
    test "loads skills from skills/*/SKILL.md directories" do
      seed_fixture_tree(Path.join(@fixtures_base, "valid"), "kits/valid")
      assert {:ok, [kit]} = Local.load_kits(dir: "kits/valid")
      skill_names = Enum.map(kit.skills, & &1.name)

      assert "files:summarize" in skill_names
      assert "tools:greet" in skill_names
    end

    test "does not recurse into skill subdirectories" do
      seed_fixture_tree(Path.join(@fixtures_base, "nested"), "kits/nested")
      assert {:ok, [kit]} = Local.load_kits(dir: "kits/nested")
      skill_names = Enum.map(kit.skills, & &1.name)

      assert "admin:delete-user" in skill_names
      assert length(kit.skills) == 1
    end

    test "detects root AGENT.md as agent" do
      seed_fixture_tree(Path.join(@fixtures_base, "with_root_agent"), "kits/with_root_agent")
      assert {:ok, [kit]} = Local.load_kits(dir: "kits/with_root_agent")
      assert kit.agent != nil
      assert kit.agent.name == "root-agent"
    end

    test "loads subagents from agents/*.md" do
      seed_fixture_tree(Path.join(@fixtures_base, "with_root_agent"), "kits/with_root_agent")
      assert {:ok, [kit]} = Local.load_kits(dir: "kits/with_root_agent")
      agent_names = Enum.map(kit.subagents, & &1.name)

      assert "helper" in agent_names
      refute "root-agent" in agent_names
    end

    test "skips non-skill subdirectories inside skills/ silently" do
      seed_fixture_tree(Path.join(@fixtures_base, "valid"), "kits/valid")
      assert {:ok, [kit]} = Local.load_kits(dir: "kits/valid")
      assert length(kit.skills) == 3
    end

    test "skips malformed skill files with warning" do
      seed_fixture_tree(Path.join(@fixtures_base, "invalid"), "kits/invalid")

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, [kit]} = Local.load_kits(dir: "kits/invalid")
          assert is_list(kit.skills)
        end)

      assert log =~ "SkillKit"
      assert log =~ "skipped"
    end

    test "kit with no root AGENT.md has nil agent" do
      seed_fixture_tree(Path.join(@fixtures_base, "valid"), "kits/valid")
      assert {:ok, [kit]} = Local.load_kits(dir: "kits/valid")
      assert is_nil(kit.agent)
    end

    test "returns {:ok, []} for nonexistent directory" do
      assert {:ok, []} = Local.load_kits(dir: "/nonexistent/path")
    end

    test "returns error for explicit dir that is not a valid kit" do
      Storage.ensure_dir!("kits/empty")
      assert {:error, :invalid_kit} = Local.load_kits(dir: "kits/empty")
    end
  end

  describe "load_kits/1 with dir: wildcard" do
    test "loads each immediate child as a separate kit" do
      seed_fixture_tree(Path.join(@fixtures_base, "wildcard"), "kits/wildcard")
      assert {:ok, kits} = Local.load_kits(dir: "kits/wildcard/*")
      kit_names = Enum.map(kits, & &1.name)

      assert "kit-a" in kit_names
      assert "kit-b" in kit_names
    end

    test "skips hidden directories silently" do
      seed_fixture_tree(Path.join(@fixtures_base, "wildcard"), "kits/wildcard")
      assert {:ok, kits} = Local.load_kits(dir: "kits/wildcard/*")
      kit_names = Enum.map(kits, & &1.name)

      refute ".hidden-kit" in kit_names
    end

    test "warns and skips non-kit directories" do
      seed_fixture_tree(Path.join(@fixtures_base, "wildcard"), "kits/wildcard")

      log =
        capture_log([level: :warning], fn ->
          assert {:ok, kits} = Local.load_kits(dir: "kits/wildcard/*")
          kit_names = Enum.map(kits, & &1.name)

          refute "not-a-kit" in kit_names
        end)

      assert log =~ "not-a-kit"
    end

    test "each kit has its own skills" do
      seed_fixture_tree(Path.join(@fixtures_base, "wildcard"), "kits/wildcard")
      assert {:ok, kits} = Local.load_kits(dir: "kits/wildcard/*")

      kit_a = Enum.find(kits, &(&1.name == "kit-a"))
      kit_b = Enum.find(kits, &(&1.name == "kit-b"))

      assert Enum.any?(kit_a.skills, &(&1.name == "kit-a:alpha"))
      assert Enum.any?(kit_b.skills, &(&1.name == "kit-b:beta"))
    end
  end
end
