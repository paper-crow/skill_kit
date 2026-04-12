defmodule SkillKit.Kit.GitHub.RefTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.GitHub.Ref

  describe "parse/1" do
    test "parses owner/repo" do
      assert {:ok, ref} = Ref.parse("paper-crow/public-skills")
      assert ref.owner == "paper-crow"
      assert ref.repo == "public-skills"
      assert ref.path == nil
      assert ref.ref == nil
    end

    test "parses owner/repo@ref" do
      assert {:ok, ref} = Ref.parse("paper-crow/public-skills@v1.0")
      assert ref.owner == "paper-crow"
      assert ref.repo == "public-skills"
      assert ref.path == nil
      assert ref.ref == "v1.0"
    end

    test "parses owner/repo/path" do
      assert {:ok, ref} = Ref.parse("paper-crow/monorepo/packages/nlp")
      assert ref.owner == "paper-crow"
      assert ref.repo == "monorepo"
      assert ref.path == "packages/nlp"
      assert ref.ref == nil
    end

    test "parses owner/repo/path@ref" do
      assert {:ok, ref} = Ref.parse("paper-crow/monorepo/packages/nlp@main")
      assert ref.owner == "paper-crow"
      assert ref.repo == "monorepo"
      assert ref.path == "packages/nlp"
      assert ref.ref == "main"
    end

    test "parses SHA refs" do
      assert {:ok, ref} = Ref.parse("owner/repo@abc123def")
      assert ref.ref == "abc123def"
    end

    test "returns error for empty string" do
      assert {:error, :invalid_reference} = Ref.parse("")
    end

    test "returns error for owner only" do
      assert {:error, :invalid_reference} = Ref.parse("owner")
    end

    test "returns error for bare @ref" do
      assert {:error, :invalid_reference} = Ref.parse("@v1.0")
    end
  end

  describe "cache_key/1" do
    test "returns owner/repo/default when no ref" do
      {:ok, ref} = Ref.parse("owner/repo")
      assert Ref.cache_key(ref) == "owner/repo/default"
    end

    test "returns owner/repo/ref when ref is present" do
      {:ok, ref} = Ref.parse("owner/repo@v1.0")
      assert Ref.cache_key(ref) == "owner/repo/v1.0"
    end
  end

  describe "display_name/1" do
    test "returns owner/repo without ref" do
      {:ok, ref} = Ref.parse("owner/repo")
      assert Ref.display_name(ref) == "owner/repo"
    end

    test "returns owner/repo@ref with ref" do
      {:ok, ref} = Ref.parse("owner/repo@v1.0")
      assert Ref.display_name(ref) == "owner/repo@v1.0"
    end
  end

  describe "allowed?/2" do
    test "wildcard * allows any source" do
      {:ok, ref} = Ref.parse("any-owner/any-repo")
      assert Ref.allowed?(ref, "*")
    end

    test "owner/* matches any repo under owner" do
      {:ok, ref} = Ref.parse("paper-crow/skills")
      assert Ref.allowed?(ref, "paper-crow/*")
    end

    test "owner/* rejects different owner" do
      {:ok, ref} = Ref.parse("evil-corp/malware")
      refute Ref.allowed?(ref, "paper-crow/*")
    end

    test "exact match owner/repo" do
      {:ok, ref} = Ref.parse("paper-crow/tools")
      assert Ref.allowed?(ref, "paper-crow/tools")
    end

    test "exact match rejects different repo" do
      {:ok, ref} = Ref.parse("paper-crow/other")
      refute Ref.allowed?(ref, "paper-crow/tools")
    end

    test "checks against a list of patterns" do
      {:ok, ref} = Ref.parse("community/helpers")
      patterns = ["paper-crow/*", "community/helpers"]
      assert Ref.allowed?(ref, patterns)
    end

    test "rejects when no pattern matches" do
      {:ok, ref} = Ref.parse("unknown/repo")
      patterns = ["paper-crow/*", "community/helpers"]
      refute Ref.allowed?(ref, patterns)
    end
  end
end
