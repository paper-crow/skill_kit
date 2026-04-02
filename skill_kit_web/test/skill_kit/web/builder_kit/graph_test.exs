defmodule SkillKit.Web.BuilderKit.GraphTest do
  use ExUnit.Case, async: true

  alias SkillKit.Web.BuilderKit.Graph

  @tmp_dir Path.join(System.tmp_dir!(), "graph_test_#{:erlang.unique_integer([:positive])}")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    {:ok, docs_root: @tmp_dir}
  end

  describe "read/1" do
    test "returns empty graph when file does not exist", %{docs_root: root} do
      assert {:ok, graph} = Graph.read(root)
      assert graph["version"] == 1
      assert graph["mappings"] == []
    end

    test "reads existing graph from disk", %{docs_root: root} do
      graph = %{"version" => 1, "mappings" => [%{"document" => "a.md", "code_files" => []}]}
      File.write!(Path.join(root, "build_graph.json"), Jason.encode!(graph))

      assert {:ok, loaded} = Graph.read(root)
      assert loaded == graph
    end

    test "returns empty graph for corrupted JSON", %{docs_root: root} do
      File.write!(Path.join(root, "build_graph.json"), "not json{{{")

      assert {:ok, graph} = Graph.read(root)
      assert graph["mappings"] == []
    end
  end

  describe "write/2" do
    test "writes graph to disk as JSON", %{docs_root: root} do
      graph = Graph.empty_graph()
      assert :ok = Graph.write(root, graph)

      {:ok, contents} = File.read(Path.join(root, "build_graph.json"))
      assert {:ok, decoded} = Jason.decode(contents)
      assert decoded["version"] == 1
    end
  end

  describe "find_mapping/2" do
    test "finds existing mapping by document path" do
      mapping = Graph.build_mapping("auth.md", code_files: ["lib/auth.ex"])
      graph = Graph.put_mapping(Graph.empty_graph(), mapping)

      assert found = Graph.find_mapping(graph, "auth.md")
      assert found["code_files"] == ["lib/auth.ex"]
    end

    test "returns nil for unmapped document" do
      assert nil == Graph.find_mapping(Graph.empty_graph(), "nope.md")
    end
  end

  describe "put_mapping/2" do
    test "adds a new mapping" do
      mapping = Graph.build_mapping("a.md")
      graph = Graph.put_mapping(Graph.empty_graph(), mapping)

      assert length(graph["mappings"]) == 1
      assert hd(graph["mappings"])["document"] == "a.md"
    end

    test "replaces existing mapping for same document" do
      m1 = Graph.build_mapping("a.md", code_files: ["old.ex"])
      m2 = Graph.build_mapping("a.md", code_files: ["new.ex"])

      graph =
        Graph.empty_graph()
        |> Graph.put_mapping(m1)
        |> Graph.put_mapping(m2)

      assert length(graph["mappings"]) == 1
      assert hd(graph["mappings"])["code_files"] == ["new.ex"]
    end
  end

  describe "remove_mapping/2" do
    test "removes mapping by document path" do
      mapping = Graph.build_mapping("a.md")

      graph =
        Graph.empty_graph()
        |> Graph.put_mapping(mapping)
        |> Graph.remove_mapping("a.md")

      assert graph["mappings"] == []
    end

    test "no-ops when document not in graph" do
      graph = Graph.remove_mapping(Graph.empty_graph(), "nope.md")
      assert graph["mappings"] == []
    end
  end

  describe "changed?/3" do
    test "returns true for unmapped document" do
      assert Graph.changed?(Graph.empty_graph(), "new.md", "content")
    end

    test "returns true when content hash differs" do
      hash = Graph.content_hash("old content")
      mapping = Graph.build_mapping("a.md", last_hash: hash)
      graph = Graph.put_mapping(Graph.empty_graph(), mapping)

      assert Graph.changed?(graph, "a.md", "new content")
    end

    test "returns false when content hash matches" do
      content = "same content"
      hash = Graph.content_hash(content)
      mapping = Graph.build_mapping("a.md", last_hash: hash)
      graph = Graph.put_mapping(Graph.empty_graph(), mapping)

      refute Graph.changed?(graph, "a.md", content)
    end
  end

  describe "content_hash/1" do
    test "returns consistent hex digest" do
      hash1 = Graph.content_hash("hello")
      hash2 = Graph.content_hash("hello")
      assert hash1 == hash2
      assert String.length(hash1) == 64
    end

    test "different content produces different hash" do
      refute Graph.content_hash("a") == Graph.content_hash("b")
    end
  end

  describe "round-trip" do
    test "write then read preserves graph", %{docs_root: root} do
      mapping = Graph.build_mapping("feat.md", code_files: ["lib/feat.ex"], last_hash: "abc123")

      graph = Graph.put_mapping(Graph.empty_graph(), mapping)
      :ok = Graph.write(root, graph)
      {:ok, loaded} = Graph.read(root)

      assert Graph.find_mapping(loaded, "feat.md")["code_files"] == ["lib/feat.ex"]
      assert Graph.find_mapping(loaded, "feat.md")["last_hash"] == "abc123"
    end
  end
end
