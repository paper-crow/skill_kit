defmodule SkillKit.Web.DocumentKit.ToolTest do
  use ExUnit.Case, async: true

  alias SkillKit.Skill
  alias SkillKit.ToolExecution
  alias SkillKit.Web.DocumentKit.Tool

  @tmp_dir Path.join(System.tmp_dir!(), "doc_kit_test_#{:erlang.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    {:ok, docs_root: @tmp_dir}
  end

  defp build_execution(skill_name, input, root) do
    %ToolExecution{
      skill: %Skill{name: skill_name},
      tool: Tool,
      input: input,
      context: %{docs_root: root},
      status: :running
    }
  end

  describe "docs:create" do
    test "writes a new file", %{docs_root: root} do
      execution =
        build_execution("docs:create", %{"path" => "guide.md", "content" => "# Hello"}, root)

      assert {:ok, _} = Tool.execute(execution)
      assert File.read!(Path.join(root, "guide.md")) == "# Hello"
    end

    test "creates intermediate directories", %{docs_root: root} do
      execution =
        build_execution(
          "docs:create",
          %{"path" => "guides/deep/new.md", "content" => "# Deep"},
          root
        )

      assert {:ok, _} = Tool.execute(execution)
      assert File.read!(Path.join(root, "guides/deep/new.md")) == "# Deep"
    end

    test "fails if file already exists", %{docs_root: root} do
      File.write!(Path.join(root, "existing.md"), "content")

      execution =
        build_execution("docs:create", %{"path" => "existing.md", "content" => "# New"}, root)

      assert {:error, _} = Tool.execute(execution)
    end
  end

  describe "docs:read" do
    test "returns file content", %{docs_root: root} do
      File.write!(Path.join(root, "doc.md"), "# Test Doc\n\nContent here.")
      execution = build_execution("docs:read", %{"path" => "doc.md"}, root)

      assert {:ok, "# Test Doc\n\nContent here."} = Tool.execute(execution)
    end

    test "fails for missing file", %{docs_root: root} do
      execution = build_execution("docs:read", %{"path" => "nope.md"}, root)

      assert {:error, _} = Tool.execute(execution)
    end
  end

  describe "docs:update" do
    test "replaces file content", %{docs_root: root} do
      File.write!(Path.join(root, "doc.md"), "old content")

      execution =
        build_execution("docs:update", %{"path" => "doc.md", "content" => "new content"}, root)

      assert {:ok, _} = Tool.execute(execution)
      assert File.read!(Path.join(root, "doc.md")) == "new content"
    end

    test "fails if file does not exist", %{docs_root: root} do
      execution =
        build_execution("docs:update", %{"path" => "missing.md", "content" => "new"}, root)

      assert {:error, _} = Tool.execute(execution)
    end
  end

  describe "docs:list" do
    test "returns all markdown files", %{docs_root: root} do
      File.mkdir_p!(Path.join(root, "guides"))
      File.write!(Path.join(root, "readme.md"), "# Readme")
      File.write!(Path.join(root, "guides/auth.md"), "# Auth")
      File.write!(Path.join(root, "not_md.txt"), "ignored")

      execution = build_execution("docs:list", %{}, root)
      {:ok, files} = Tool.execute(execution)

      assert "readme.md" in files
      assert "guides/auth.md" in files
      refute "not_md.txt" in files
    end

    test "returns empty list when no markdown files", %{docs_root: root} do
      execution = build_execution("docs:list", %{}, root)
      assert {:ok, []} = Tool.execute(execution)
    end
  end

  describe "docs:search" do
    test "finds matching content", %{docs_root: root} do
      File.write!(Path.join(root, "doc.md"), "# Auth\n\nUsers authenticate via email.")
      execution = build_execution("docs:search", %{"query" => "authenticate"}, root)

      {:ok, results} = Tool.execute(execution)
      assert length(results) > 0
      assert hd(results).path == "doc.md"
    end

    test "returns empty list when no matches", %{docs_root: root} do
      File.write!(Path.join(root, "doc.md"), "# Hello\n\nWorld.")
      execution = build_execution("docs:search", %{"query" => "nonexistent"}, root)

      assert {:ok, []} = Tool.execute(execution)
    end
  end

  describe "docs:structure" do
    test "returns heading structure", %{docs_root: root} do
      content = "# Title\n\n## Section 1\n\nText.\n\n### Subsection\n\n## Section 2\n"
      File.write!(Path.join(root, "doc.md"), content)
      execution = build_execution("docs:structure", %{"path" => "doc.md"}, root)

      {:ok, headings} = Tool.execute(execution)
      assert length(headings) == 4
      assert hd(headings) == %{level: 1, text: "Title"}
    end

    test "returns empty list for empty file", %{docs_root: root} do
      File.write!(Path.join(root, "empty.md"), "")
      execution = build_execution("docs:structure", %{"path" => "empty.md"}, root)

      assert {:ok, []} = Tool.execute(execution)
    end

    test "returns error for missing file", %{docs_root: root} do
      execution = build_execution("docs:structure", %{"path" => "nope.md"}, root)

      assert {:error, _} = Tool.execute(execution)
    end
  end

  describe "docs:history" do
    test "returns git log for a file", %{docs_root: root} do
      # Initialize a git repo so we can test history
      System.cmd("git", ["init"], cd: root)
      System.cmd("git", ["config", "user.email", "test@test.com"], cd: root)
      System.cmd("git", ["config", "user.name", "Test"], cd: root)
      File.write!(Path.join(root, "doc.md"), "# Doc")
      System.cmd("git", ["add", "doc.md"], cd: root)
      System.cmd("git", ["commit", "-m", "init"], cd: root)

      execution = build_execution("docs:history", %{"path" => "doc.md"}, root)
      {:ok, log} = Tool.execute(execution)

      assert is_binary(log)
      assert log =~ "init"
    end

    test "returns error when not a git repo", %{docs_root: root} do
      File.write!(Path.join(root, "doc.md"), "# Doc")
      execution = build_execution("docs:history", %{"path" => "doc.md"}, root)

      assert {:error, _} = Tool.execute(execution)
    end
  end

  describe "path traversal prevention" do
    test "prevents reading outside project root", %{docs_root: root} do
      execution = build_execution("docs:read", %{"path" => "../../../etc/passwd"}, root)

      assert {:error, _} = Tool.execute(execution)
    end

    test "prevents creating outside project root", %{docs_root: root} do
      execution =
        build_execution("docs:create", %{"path" => "../escape.md", "content" => "bad"}, root)

      assert {:error, _} = Tool.execute(execution)
    end
  end

  describe "definition/0" do
    test "returns a tool struct" do
      tool = Tool.definition()

      assert tool.name == "docs"
      assert tool.description != ""
      assert is_map(tool.input_schema)
    end
  end

  describe "unknown skill" do
    test "returns error for unknown skill name", %{docs_root: root} do
      execution = build_execution("docs:unknown", %{}, root)

      assert {:error, "Unknown skill: docs:unknown"} = Tool.execute(execution)
    end
  end

  describe "resume/3" do
    test "returns not_resumable" do
      assert {:error, :not_resumable} = Tool.resume(nil, nil, nil)
    end
  end
end
