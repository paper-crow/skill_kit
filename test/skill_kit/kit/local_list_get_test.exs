defmodule SkillKit.Kit.Local.ListGetTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.Local

  @fixtures_dir Path.expand("../../fixtures/local_list_get", __DIR__)

  setup do
    File.mkdir_p!("#{@fixtures_dir}/my_kit")

    File.write!("#{@fixtures_dir}/my_kit/hello.skill.md", ~S"""
    ---
    name: "my_kit:hello"
    description: "Hello skill"
    ---
    Say hello.
    """)

    on_exit(fn -> File.rm_rf!(@fixtures_dir) end)
    %{dir: @fixtures_dir}
  end

  describe "list_kits/1" do
    test "returns kits from directory", %{dir: dir} do
      assert {:ok, kits} = Local.list_kits(dir: dir)
      assert length(kits) >= 1

      kit = Enum.find(kits, &(&1.name == "my_kit"))
      assert kit != nil
      assert length(kit.skills) == 1
    end

    test "returns empty list for nonexistent directory" do
      assert {:ok, []} = Local.list_kits(dir: "/nonexistent")
    end
  end

  describe "get_kit/2" do
    test "returns kit by name", %{dir: dir} do
      assert {:ok, kit} = Local.get_kit([dir: dir], "my_kit")
      assert kit.name == "my_kit"
      assert length(kit.skills) == 1
    end

    test "returns error for unknown kit" do
      assert {:error, :not_found} = Local.get_kit([dir: "/nonexistent"], "nope")
    end
  end
end
