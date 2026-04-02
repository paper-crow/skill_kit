defmodule SkillKit.Web.BuilderKit.ToolTest do
  use ExUnit.Case, async: true

  alias SkillKit.Skill
  alias SkillKit.ToolExecution
  alias SkillKit.Web.BuilderKit.Graph
  alias SkillKit.Web.BuilderKit.Tool

  @tmp_dir Path.join(System.tmp_dir!(), "builder_tool_test_#{:erlang.unique_integer([:positive])}")

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

  describe "build:graph_read" do
    test "returns empty graph when no file exists", %{docs_root: root} do
      execution = build_execution("build:graph_read", %{}, root)
      {:ok, json} = Tool.execute(execution)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["mappings"] == []
    end

    test "returns existing graph", %{docs_root: root} do
      mapping = Graph.build_mapping("a.md", code_files: ["lib/a.ex"])
      graph = Graph.put_mapping(Graph.empty_graph(), mapping)
      Graph.write(root, graph)

      execution = build_execution("build:graph_read", %{}, root)
      {:ok, json} = Tool.execute(execution)
      {:ok, decoded} = Jason.decode(json)

      assert length(decoded["mappings"]) == 1
      assert hd(decoded["mappings"])["document"] == "a.md"
    end
  end

  describe "build:graph_link" do
    test "creates new mapping", %{docs_root: root} do
      input = %{"document" => "auth.md", "code_files" => ["lib/auth.ex"]}
      execution = build_execution("build:graph_link", input, root)

      assert {:ok, _} = Tool.execute(execution)

      {:ok, graph} = Graph.read(root)
      mapping = Graph.find_mapping(graph, "auth.md")
      assert mapping["code_files"] == ["lib/auth.ex"]
    end

    test "merges code files with existing mapping", %{docs_root: root} do
      mapping = Graph.build_mapping("auth.md", code_files: ["lib/auth.ex"])
      graph = Graph.put_mapping(Graph.empty_graph(), mapping)
      Graph.write(root, graph)

      input = %{"document" => "auth.md", "code_files" => ["lib/auth/token.ex"]}
      execution = build_execution("build:graph_link", input, root)
      assert {:ok, _} = Tool.execute(execution)

      {:ok, updated} = Graph.read(root)
      files = Graph.find_mapping(updated, "auth.md")["code_files"]
      assert "lib/auth.ex" in files
      assert "lib/auth/token.ex" in files
    end
  end

  describe "build:graph_unlink" do
    test "removes mapping", %{docs_root: root} do
      mapping = Graph.build_mapping("auth.md", code_files: ["lib/auth.ex"])
      graph = Graph.put_mapping(Graph.empty_graph(), mapping)
      Graph.write(root, graph)

      input = %{"document" => "auth.md"}
      execution = build_execution("build:graph_unlink", input, root)
      assert {:ok, _} = Tool.execute(execution)

      {:ok, updated} = Graph.read(root)
      assert Graph.find_mapping(updated, "auth.md") == nil
    end

    test "no-ops for unmapped document", %{docs_root: root} do
      input = %{"document" => "nope.md"}
      execution = build_execution("build:graph_unlink", input, root)
      assert {:ok, _} = Tool.execute(execution)
    end
  end

  describe "build:graph_update" do
    test "updates hash and artifact paths", %{docs_root: root} do
      mapping = Graph.build_mapping("auth.md", code_files: ["lib/auth.ex"])
      graph = Graph.put_mapping(Graph.empty_graph(), mapping)
      Graph.write(root, graph)

      input = %{
        "document" => "auth.md",
        "last_hash" => "abc123",
        "requirements" => ".build/requirements/auth.md",
        "plan" => ".build/plans/auth.md"
      }

      execution = build_execution("build:graph_update", input, root)
      assert {:ok, _} = Tool.execute(execution)

      {:ok, updated} = Graph.read(root)
      m = Graph.find_mapping(updated, "auth.md")
      assert m["last_hash"] == "abc123"
      assert m["requirements"] == ".build/requirements/auth.md"
      assert m["plan"] == ".build/plans/auth.md"
      assert m["code_files"] == ["lib/auth.ex"]
    end

    test "creates mapping if document not yet tracked", %{docs_root: root} do
      input = %{"document" => "new.md", "last_hash" => "def456"}
      execution = build_execution("build:graph_update", input, root)
      assert {:ok, _} = Tool.execute(execution)

      {:ok, graph} = Graph.read(root)
      assert Graph.find_mapping(graph, "new.md")["last_hash"] == "def456"
    end
  end

  describe "unknown skill" do
    test "returns error", %{docs_root: root} do
      execution = build_execution("build:unknown", %{}, root)
      assert {:error, "Unknown skill: build:unknown"} = Tool.execute(execution)
    end
  end

  describe "definition/0" do
    test "returns a tool struct" do
      tool = Tool.definition()
      assert tool.name == "build"
      assert is_map(tool.input_schema)
    end
  end

  describe "resume/3" do
    test "returns not_resumable" do
      assert {:error, :not_resumable} = Tool.resume(nil, nil, nil)
    end
  end
end
