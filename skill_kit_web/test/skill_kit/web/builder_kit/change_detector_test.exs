defmodule SkillKit.Web.BuilderKit.ChangeDetectorTest do
  use ExUnit.Case, async: true

  alias SkillKit.Web.BuilderKit.ChangeDetector
  alias SkillKit.Web.BuilderKit.Graph

  @tmp_dir Path.join(
             System.tmp_dir!(),
             "change_detector_test_#{:erlang.unique_integer([:positive])}"
           )

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    {:ok, docs_root: @tmp_dir}
  end

  test "returns :no_change for untracked document", %{docs_root: root} do
    assert :no_change = ChangeDetector.check(root, "untracked.md", "content")
  end

  test "returns :no_change when content hash matches", %{docs_root: root} do
    content = "# Hello\n\nSame content."
    hash = Graph.content_hash(content)

    mapping = Graph.build_mapping("doc.md", last_hash: hash, code_files: ["lib/a.ex"])
    graph = Graph.put_mapping(Graph.empty_graph(), mapping)
    Graph.write(root, graph)

    assert :no_change = ChangeDetector.check(root, "doc.md", content)
  end

  test "returns {:changed, info} when content hash differs", %{docs_root: root} do
    old_hash = Graph.content_hash("old content")
    mapping = Graph.build_mapping("doc.md", last_hash: old_hash, code_files: ["lib/a.ex"])
    graph = Graph.put_mapping(Graph.empty_graph(), mapping)
    Graph.write(root, graph)

    assert {:changed, change} = ChangeDetector.check(root, "doc.md", "new content")
    assert change.document == "doc.md"
    assert change.code_files == ["lib/a.ex"]
    assert change.new_hash == Graph.content_hash("new content")
  end

  test "returns :no_change when graph file is missing", %{docs_root: root} do
    assert :no_change = ChangeDetector.check(root, "any.md", "content")
  end

  test "format_agent_message includes document path and code files" do
    change = %{
      document: "features/auth.md",
      new_hash: "abc",
      code_files: ["lib/auth.ex", "lib/auth/token.ex"],
      requirements: nil,
      plan: nil
    }

    msg = ChangeDetector.format_agent_message(change)
    assert msg =~ "features/auth.md"
    assert msg =~ "lib/auth.ex"
    assert msg =~ "lib/auth/token.ex"
  end

  test "format_agent_message handles empty code files" do
    change = %{
      document: "intro.md",
      new_hash: "abc",
      code_files: [],
      requirements: nil,
      plan: nil
    }

    msg = ChangeDetector.format_agent_message(change)
    assert msg =~ "No code files are linked yet"
  end
end
