defmodule SkillKit.Kit.Local.ListGetTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.Local

  @fixtures_dir Path.expand("../../fixtures/local_list_get", __DIR__)

  setup do
    # Create a kit with the new directory structure
    kit_dir = Path.join(@fixtures_dir, "my_kit")
    skill_dir = Path.join([kit_dir, "skills", "hello"])
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: "my_kit:hello"
    description: "Hello skill"
    ---
    Say hello.
    """)

    on_exit(fn -> File.rm_rf!(@fixtures_dir) end)
    %{dir: @fixtures_dir, kit_dir: kit_dir}
  end

  describe "list_kits/1" do
    test "returns kit from explicit directory", %{kit_dir: kit_dir} do
      assert {:ok, [kit]} = Local.list_kits(dir: kit_dir)
      assert kit.name == "my_kit"
      assert kit.skills != []
    end

    test "returns empty list for nonexistent directory" do
      assert {:ok, []} = Local.list_kits(dir: "/nonexistent")
    end
  end

  describe "get_kit/2" do
    test "returns kit by name", %{kit_dir: kit_dir} do
      assert {:ok, kit} = Local.get_kit([dir: kit_dir], "my_kit")
      assert kit.name == "my_kit"
      assert kit.skills != []
    end

    test "returns error for unknown kit" do
      assert {:error, :not_found} = Local.get_kit([dir: "/nonexistent"], "nope")
    end
  end
end
