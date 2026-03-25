defmodule SkillKit.Kit.MemoryTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit
  alias SkillKit.Kit.Memory
  alias SkillKit.Skill

  setup do
    {:ok, pid} = Memory.start_link([])
    %{provider: pid}
  end

  describe "put_kit/2 and list_kits/1" do
    test "stores and retrieves kits", %{provider: pid} do
      kit = %Kit{
        name: "test_kit",
        skills: [%Skill{name: "test_kit:hello", description: "Hello", body: "Say hello."}]
      }

      :ok = Memory.put_kit(pid, kit)

      {:ok, kits} = Memory.list_kits(provider: pid)
      assert length(kits) == 1
      assert hd(kits).name == "test_kit"
    end

    test "replaces kit with same name", %{provider: pid} do
      :ok = Memory.put_kit(pid, %Kit{name: "k", skills: []})

      :ok =
        Memory.put_kit(pid, %Kit{
          name: "k",
          skills: [%Skill{name: "k:a", description: "A", body: "a"}]
        })

      {:ok, [kit]} = Memory.list_kits(provider: pid)
      assert length(kit.skills) == 1
    end
  end

  describe "get_kit/2" do
    test "returns kit by name", %{provider: pid} do
      :ok = Memory.put_kit(pid, %Kit{name: "my_kit", skills: []})

      assert {:ok, kit} = Memory.get_kit([provider: pid], "my_kit")
      assert kit.name == "my_kit"
    end

    test "returns error for unknown kit", %{provider: pid} do
      assert {:error, :not_found} = Memory.get_kit([provider: pid], "nope")
    end
  end

  describe "put/2 convenience" do
    test "wraps a skill in an auto-named kit", %{provider: pid} do
      skill = %Skill{name: "ns:hello", description: "Hello", body: "Say hello."}
      :ok = Memory.put(pid, skill)

      {:ok, kits} = Memory.list_kits(provider: pid)
      assert length(kits) == 1

      [kit] = kits
      assert kit.name == "ns"
      assert length(kit.skills) == 1
    end

    test "groups skills by namespace into kits", %{provider: pid} do
      :ok = Memory.put(pid, %Skill{name: "ns:a", description: "A", body: "a"})
      :ok = Memory.put(pid, %Skill{name: "ns:b", description: "B", body: "b"})

      {:ok, [kit]} = Memory.list_kits(provider: pid)
      assert kit.name == "ns"
      assert length(kit.skills) == 2
    end
  end

  describe "delete/2" do
    test "removes a skill and cleans up empty kit", %{provider: pid} do
      :ok = Memory.put(pid, %Skill{name: "ns:hello", description: "Hello", body: "hello"})
      :ok = Memory.delete(pid, "ns:hello")

      {:ok, kits} = Memory.list_kits(provider: pid)
      assert kits == []
    end
  end

  describe "empty provider" do
    test "returns empty list", %{provider: pid} do
      {:ok, kits} = Memory.list_kits(provider: pid)
      assert kits == []
    end
  end
end
