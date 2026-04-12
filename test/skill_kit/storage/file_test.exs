defmodule SkillKit.Storage.FileTest do
  use ExUnit.Case, async: true

  alias SkillKit.Storage

  @test_dir Path.join(
              System.tmp_dir!(),
              "skill_kit_storage_file_test_#{:erlang.unique_integer([:positive])}"
            )

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  describe "put/2 and read/1" do
    test "round-trips binary content" do
      path = Path.join(@test_dir, "hello.txt")
      assert :ok = Storage.File.put(path, "hello world")
      assert {:ok, "hello world"} = Storage.File.read(path)
    end

    test "read returns error for missing file" do
      assert {:error, :enoent} = Storage.File.read(Path.join(@test_dir, "missing.txt"))
    end
  end

  describe "exists?/1 and dir?/1" do
    test "exists? returns false for missing path" do
      refute Storage.File.exists?(Path.join(@test_dir, "nope"))
    end

    test "exists? returns true for file" do
      path = Path.join(@test_dir, "exists.txt")
      Storage.File.put(path, "data")
      assert Storage.File.exists?(path)
    end

    test "dir? returns true for directory" do
      assert Storage.File.dir?(@test_dir)
    end

    test "dir? returns false for file" do
      path = Path.join(@test_dir, "file.txt")
      Storage.File.put(path, "data")
      refute Storage.File.dir?(path)
    end
  end

  describe "ensure_dir/1" do
    test "creates nested directories" do
      nested = Path.join([@test_dir, "a", "b", "c"])
      assert :ok = Storage.File.ensure_dir(nested)
      assert Storage.File.dir?(nested)
    end

    test "is idempotent" do
      assert :ok = Storage.File.ensure_dir(@test_dir)
      assert :ok = Storage.File.ensure_dir(@test_dir)
    end
  end

  describe "list/1" do
    test "lists direct children" do
      Storage.File.put(Path.join(@test_dir, "a.txt"), "a")
      Storage.File.put(Path.join(@test_dir, "b.txt"), "b")
      File.mkdir_p!(Path.join(@test_dir, "subdir"))

      assert {:ok, entries} = Storage.File.list(@test_dir)
      entries = Enum.sort(entries)
      assert entries == ["a.txt", "b.txt", "subdir"]
    end

    test "returns error for missing directory" do
      assert {:error, :enoent} = Storage.File.list(Path.join(@test_dir, "nope"))
    end
  end

  describe "delete/1" do
    test "removes a file" do
      path = Path.join(@test_dir, "to_delete.txt")
      Storage.File.put(path, "data")
      assert :ok = Storage.File.delete(path)
      refute Storage.File.exists?(path)
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = Storage.File.delete(Path.join(@test_dir, "missing"))
    end
  end

  describe "delete_all/1" do
    test "recursively removes directory and contents" do
      nested = Path.join([@test_dir, "parent", "child"])
      File.mkdir_p!(nested)
      Storage.File.put(Path.join(nested, "file.txt"), "data")

      assert {:ok, _files} = Storage.File.delete_all(Path.join(@test_dir, "parent"))
      refute Storage.File.exists?(Path.join(@test_dir, "parent"))
    end
  end

  describe "delete_dir/1" do
    test "removes empty directory" do
      dir = Path.join(@test_dir, "empty")
      File.mkdir_p!(dir)
      assert :ok = Storage.File.delete_dir(dir)
      refute Storage.File.exists?(dir)
    end
  end
end
