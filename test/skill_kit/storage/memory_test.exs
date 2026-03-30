defmodule SkillKit.Storage.MemoryTest do
  use ExUnit.Case, async: false

  alias SkillKit.Storage

  setup do
    start_supervised!(Storage.Memory)
    :ok
  end

  describe "put/2 and read/1" do
    test "round-trips binary content" do
      assert :ok = Storage.Memory.put("files/hello.txt", "hello world")
      assert {:ok, "hello world"} = Storage.Memory.read("files/hello.txt")
    end

    test "read returns error for missing path" do
      assert {:error, :enoent} = Storage.Memory.read("missing.txt")
    end

    test "overwrites existing content" do
      Storage.Memory.put("f.txt", "old")
      Storage.Memory.put("f.txt", "new")
      assert {:ok, "new"} = Storage.Memory.read("f.txt")
    end
  end

  describe "exists?/1" do
    test "returns false for missing path" do
      refute Storage.Memory.exists?("nope")
    end

    test "returns true for file" do
      Storage.Memory.put("exists.txt", "data")
      assert Storage.Memory.exists?("exists.txt")
    end

    test "returns true for explicit directory" do
      Storage.Memory.ensure_dir("mydir")
      assert Storage.Memory.exists?("mydir")
    end
  end

  describe "dir?/1" do
    test "returns true for explicit directory" do
      Storage.Memory.ensure_dir("mydir")
      assert Storage.Memory.dir?("mydir")
    end

    test "returns true for implicit directory (parent of a file)" do
      Storage.Memory.put("parent/child.txt", "data")
      assert Storage.Memory.dir?("parent")
    end

    test "returns true for deeply nested implicit directory" do
      Storage.Memory.put("a/b/c/file.txt", "data")
      assert Storage.Memory.dir?("a")
      assert Storage.Memory.dir?("a/b")
      assert Storage.Memory.dir?("a/b/c")
    end

    test "returns false for file" do
      Storage.Memory.put("file.txt", "data")
      refute Storage.Memory.dir?("file.txt")
    end

    test "returns false for missing path" do
      refute Storage.Memory.dir?("nope")
    end
  end

  describe "ensure_dir/1" do
    test "creates a directory entry" do
      assert :ok = Storage.Memory.ensure_dir("mydir")
      assert Storage.Memory.dir?("mydir")
    end

    test "is idempotent" do
      assert :ok = Storage.Memory.ensure_dir("mydir")
      assert :ok = Storage.Memory.ensure_dir("mydir")
    end

    test "creates nested path segments" do
      assert :ok = Storage.Memory.ensure_dir("a/b/c")
      assert Storage.Memory.dir?("a")
      assert Storage.Memory.dir?("a/b")
      assert Storage.Memory.dir?("a/b/c")
    end
  end

  describe "list/1" do
    test "lists direct children (files and dirs)" do
      Storage.Memory.put("root/a.txt", "a")
      Storage.Memory.put("root/b.txt", "b")
      Storage.Memory.ensure_dir("root/subdir")

      assert {:ok, entries} = Storage.Memory.list("root")
      assert Enum.sort(entries) == ["a.txt", "b.txt", "subdir"]
    end

    test "does not include nested children" do
      Storage.Memory.put("root/sub/deep.txt", "data")
      Storage.Memory.put("root/top.txt", "data")

      assert {:ok, entries} = Storage.Memory.list("root")
      assert Enum.sort(entries) == ["sub", "top.txt"]
    end

    test "returns error for missing directory" do
      assert {:error, :enoent} = Storage.Memory.list("nope")
    end
  end

  describe "delete/1" do
    test "removes a file" do
      Storage.Memory.put("file.txt", "data")
      assert :ok = Storage.Memory.delete("file.txt")
      refute Storage.Memory.exists?("file.txt")
    end

    test "returns error for missing path" do
      assert {:error, :enoent} = Storage.Memory.delete("missing")
    end
  end

  describe "delete_all/1" do
    test "removes path and all children" do
      Storage.Memory.put("parent/child/file.txt", "data")
      Storage.Memory.put("parent/other.txt", "data")
      Storage.Memory.ensure_dir("parent/child")

      assert {:ok, _paths} = Storage.Memory.delete_all("parent")
      refute Storage.Memory.exists?("parent")
      refute Storage.Memory.exists?("parent/child/file.txt")
      refute Storage.Memory.exists?("parent/other.txt")
    end

    test "returns ok with empty list for missing path" do
      assert {:ok, []} = Storage.Memory.delete_all("missing")
    end
  end

  describe "delete_dir/1" do
    test "removes empty explicit directory" do
      Storage.Memory.ensure_dir("empty")
      assert :ok = Storage.Memory.delete_dir("empty")
      refute Storage.Memory.exists?("empty")
    end

    test "returns error when directory has children" do
      Storage.Memory.put("notempty/file.txt", "data")
      Storage.Memory.ensure_dir("notempty")
      assert {:error, :eexist} = Storage.Memory.delete_dir("notempty")
    end
  end

  describe "isolation via start_supervised!" do
    test "state is isolated per test — store is empty" do
      assert {:error, :enoent} = Storage.Memory.read("files/hello.txt")
    end
  end
end
