defmodule SkillKit.Kit.GitHub.CacheTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.GitHub.Cache
  alias SkillKit.Kit.GitHub.Ref

  setup do
    cache_dir =
      Path.join(System.tmp_dir!(), "skill_kit_cache_test_#{:erlang.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(cache_dir) end)

    %{cache_dir: cache_dir}
  end

  describe "extract/3" do
    test "extracts tarball to cache directory", %{cache_dir: cache_dir} do
      tarball = create_test_tarball("owner-repo-abc123", "skills/greet/SKILL.md", skill_content())
      {:ok, ref} = Ref.parse("owner/repo@main")

      assert {:ok, kit_dir} = Cache.extract(tarball, ref, cache_dir)
      assert File.dir?(kit_dir)
      assert File.exists?(Path.join([kit_dir, "skills", "greet", "SKILL.md"]))
    end

    test "strips the top-level GitHub directory prefix", %{cache_dir: cache_dir} do
      tarball = create_test_tarball("owner-repo-abc123", "skills/greet/SKILL.md", skill_content())
      {:ok, ref} = Ref.parse("owner/repo@main")

      {:ok, kit_dir} = Cache.extract(tarball, ref, cache_dir)

      refute File.dir?(Path.join(kit_dir, "owner-repo-abc123"))
    end

    test "uses path subdirectory when ref has path", %{cache_dir: cache_dir} do
      tarball =
        create_test_tarball(
          "owner-repo-abc123",
          "packages/nlp/skills/greet/SKILL.md",
          skill_content()
        )

      {:ok, ref} = Ref.parse("owner/repo/packages/nlp@main")

      {:ok, kit_dir} = Cache.extract(tarball, ref, cache_dir)
      assert String.ends_with?(kit_dir, "packages/nlp")
      assert File.exists?(Path.join([kit_dir, "skills", "greet", "SKILL.md"]))
    end
  end

  describe "exists?/2" do
    test "returns false when not cached", %{cache_dir: cache_dir} do
      {:ok, ref} = Ref.parse("owner/repo@main")
      refute Cache.exists?(ref, cache_dir)
    end

    test "returns true after extraction", %{cache_dir: cache_dir} do
      tarball = create_test_tarball("owner-repo-abc123", "skills/greet/SKILL.md", skill_content())
      {:ok, ref} = Ref.parse("owner/repo@main")

      {:ok, _} = Cache.extract(tarball, ref, cache_dir)
      assert Cache.exists?(ref, cache_dir)
    end
  end

  describe "kit_dir/2" do
    test "returns the expected cache path", %{cache_dir: cache_dir} do
      {:ok, ref} = Ref.parse("owner/repo@v1.0")
      assert Cache.kit_dir(ref, cache_dir) == Path.join([cache_dir, "owner", "repo", "v1.0"])
    end

    test "uses 'default' for nil ref", %{cache_dir: cache_dir} do
      {:ok, ref} = Ref.parse("owner/repo")
      assert Cache.kit_dir(ref, cache_dir) == Path.join([cache_dir, "owner", "repo", "default"])
    end
  end

  describe "list_cached/1" do
    test "returns empty list for empty cache", %{cache_dir: cache_dir} do
      assert Cache.list_cached(cache_dir) == []
    end

    test "returns cached refs after extraction", %{cache_dir: cache_dir} do
      tarball = create_test_tarball("owner-repo-abc123", "skills/greet/SKILL.md", skill_content())
      {:ok, ref} = Ref.parse("owner/repo@main")
      {:ok, _} = Cache.extract(tarball, ref, cache_dir)

      cached = Cache.list_cached(cache_dir)
      assert length(cached) == 1
      assert hd(cached) == %{owner: "owner", repo: "repo", ref: "main"}
    end
  end

  describe "remove/2" do
    test "deletes cached directory", %{cache_dir: cache_dir} do
      tarball = create_test_tarball("owner-repo-abc123", "skills/greet/SKILL.md", skill_content())
      {:ok, ref} = Ref.parse("owner/repo@main")
      {:ok, _} = Cache.extract(tarball, ref, cache_dir)

      assert :ok = Cache.remove(ref, cache_dir)
      refute Cache.exists?(ref, cache_dir)
    end

    test "returns ok when nothing to remove", %{cache_dir: cache_dir} do
      {:ok, ref} = Ref.parse("owner/repo@main")
      assert :ok = Cache.remove(ref, cache_dir)
    end

    test "cleans up empty parent directories", %{cache_dir: cache_dir} do
      tarball = create_test_tarball("owner-repo-abc123", "skills/greet/SKILL.md", skill_content())
      {:ok, ref} = Ref.parse("owner/repo@main")
      {:ok, _} = Cache.extract(tarball, ref, cache_dir)

      Cache.remove(ref, cache_dir)

      refute File.dir?(Path.join([cache_dir, "owner", "repo"]))
      refute File.dir?(Path.join([cache_dir, "owner"]))
    end
  end

  defp skill_content do
    """
    ---
    name: "test:greet"
    description: "A greeting skill"
    ---
    Say hello to the user.
    """
  end

  defp create_test_tarball(prefix, file_path, content) do
    full_path = String.to_charlist("#{prefix}/#{file_path}")
    path = Path.join(System.tmp_dir!(), "cache_test_#{:erlang.unique_integer([:positive])}.tar")
    :ok = :erl_tar.create(String.to_charlist(path), [{full_path, content}], [])
    tar_data = File.read!(path)
    File.rm!(path)
    :zlib.gzip(tar_data)
  end
end
