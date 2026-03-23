defmodule SkillKit.FrontmatterTest do
  use ExUnit.Case, async: true

  alias SkillKit.Frontmatter

  describe "parse/1" do
    test "parses valid frontmatter with body" do
      content = """
      ---
      name: test
      description: A test
      ---
      Body content here.
      """

      assert {:ok, %{"name" => "test", "description" => "A test"}, "Body content here."} =
               Frontmatter.parse(content)
    end

    test "parses frontmatter with empty body" do
      content = """
      ---
      name: test
      ---
      """

      assert {:ok, %{"name" => "test"}, ""} = Frontmatter.parse(content)
    end

    test "parses frontmatter with multiline body" do
      content = """
      ---
      name: test
      ---
      Line one.

      Line two.
      """

      assert {:ok, _yaml, body} = Frontmatter.parse(content)
      assert String.contains?(body, "Line one.")
      assert String.contains?(body, "Line two.")
    end

    test "returns error for missing frontmatter delimiters" do
      assert {:error, :invalid_frontmatter} = Frontmatter.parse("no frontmatter here")
    end

    test "returns error for invalid YAML" do
      content = """
      ---
      invalid: [unclosed
      ---
      body
      """

      assert {:error, %YamlElixir.ParsingError{}} = Frontmatter.parse(content)
    end

    test "parses metadata with nested values" do
      content = """
      ---
      name: test
      metadata:
        workspace: ~/.agents/test
        max_agent_depth: "2"
      ---
      body
      """

      assert {:ok, yaml, _body} = Frontmatter.parse(content)
      assert yaml["metadata"]["workspace"] == "~/.agents/test"
    end
  end

  describe "parse_file/1" do
    test "reads and parses a file" do
      path =
        Path.join(System.tmp_dir!(), "test_frontmatter_#{:erlang.unique_integer([:positive])}.md")

      File.write!(path, """
      ---
      name: from-file
      ---
      File body.
      """)

      assert {:ok, %{"name" => "from-file"}, "File body."} = Frontmatter.parse_file(path)
      File.rm!(path)
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = Frontmatter.parse_file("/nonexistent/file.md")
    end
  end
end
