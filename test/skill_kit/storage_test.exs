defmodule SkillKit.StorageTest do
  use ExUnit.Case, async: false

  alias SkillKit.Storage

  setup do
    start_supervised!(Storage.Memory)
    :ok
  end

  describe "convenience API delegates to configured provider" do
    test "put/2 and read/1" do
      assert :ok = Storage.put("test.txt", "data")
      assert {:ok, "data"} = Storage.read("test.txt")
    end

    test "exists?/1" do
      refute Storage.exists?("nope")
      Storage.put("yes.txt", "data")
      assert Storage.exists?("yes.txt")
    end

    test "dir?/1" do
      Storage.ensure_dir("mydir")
      assert Storage.dir?("mydir")
    end

    test "list/1" do
      Storage.put("dir/a.txt", "a")
      Storage.put("dir/b.txt", "b")
      assert {:ok, entries} = Storage.list("dir")
      assert Enum.sort(entries) == ["a.txt", "b.txt"]
    end

    test "delete/1" do
      Storage.put("del.txt", "data")
      assert :ok = Storage.delete("del.txt")
      refute Storage.exists?("del.txt")
    end

    test "delete_all/1" do
      Storage.put("parent/child.txt", "data")
      assert {:ok, _} = Storage.delete_all("parent")
      refute Storage.exists?("parent/child.txt")
    end

    test "ensure_dir/1" do
      assert :ok = Storage.ensure_dir("new/nested/dir")
      assert Storage.dir?("new/nested/dir")
    end

    test "delete_dir/1" do
      Storage.ensure_dir("empty")
      assert :ok = Storage.delete_dir("empty")
    end
  end

  describe "bang wrappers" do
    test "put!/2 returns :ok on success" do
      assert :ok = Storage.put!("bang.txt", "data")
      assert {:ok, "data"} = Storage.read("bang.txt")
    end

    test "ensure_dir!/1 returns :ok on success" do
      assert :ok = Storage.ensure_dir!("bang_dir")
      assert Storage.dir?("bang_dir")
    end

    test "delete_all!/1 returns list of removed paths" do
      Storage.put("rm/a.txt", "a")
      removed = Storage.delete_all!("rm")
      assert is_list(removed)
    end
  end
end
