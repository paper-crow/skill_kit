defmodule SkillKit.Kit.Local.ParserTest do
  use ExUnit.Case, async: true

  alias SkillKit.Kit.Local.Parser
  alias SkillKit.Skill

  @fixtures_path Path.join([__DIR__, "..", "..", "..", "support", "fixtures", "skills"])
  @valid_path Path.join([__DIR__, "..", "..", "..", "support", "fixtures", "skills", "valid"])

  # ---------------------------------------------------------------------------
  # load_file/1 — valid files
  # ---------------------------------------------------------------------------

  describe "load_file/1 with valid files" do
    test "returns {:ok, %Skill{}} for summarize.skill.md — full round-trip" do
      path = Path.join(@fixtures_path, "valid/summarize.skill.md")
      assert {:ok, %Skill{} = skill} = Parser.load_file(path)
      assert skill.name == "files:summarize"
      assert skill.namespace == "files"
      assert skill.description == "Summarize a file's contents"
      assert skill.required_scope == ["files:read"]
      assert skill.location == path
      assert skill.handler == SkillKit.Shell
      assert skill.hooks == []
      assert String.contains?(skill.body, "{{content}}")
    end

    test "returns {:ok, %Skill{}} for multi_arg.skill.md — multiple template vars" do
      path = Path.join(@fixtures_path, "valid/multi_arg.skill.md")
      assert {:ok, %Skill{} = skill} = Parser.load_file(path)
      assert skill.name == "tools:greet"
      assert skill.description == "Generate a greeting"
      assert String.contains?(skill.body, "{{name}}")
      assert String.contains?(skill.body, "{{place}}")
    end

    test "body has leading/trailing whitespace trimmed" do
      path = Path.join(@fixtures_path, "valid/summarize.skill.md")
      {:ok, skill} = Parser.load_file(path)
      assert skill.body == String.trim(skill.body)
    end

    test "required_scope is a list of strings for summarize fixture" do
      path = Path.join(@fixtures_path, "valid/summarize.skill.md")
      {:ok, skill} = Parser.load_file(path)
      assert is_list(skill.required_scope)
      assert Enum.all?(skill.required_scope, &is_binary/1)
    end
  end

  # ---------------------------------------------------------------------------
  # load_file/1 — invalid files
  # ---------------------------------------------------------------------------

  describe "load_file/1 with invalid files" do
    test "returns {:error, {:missing_field, \"name\"}} when name field absent" do
      path = Path.join(@fixtures_path, "invalid/missing_name.skill.md")
      assert {:error, {:missing_field, "name"}} = Parser.load_file(path)
    end

    test "returns {:error, %YamlElixir.ParsingError{}} for invalid YAML" do
      path = Path.join(@fixtures_path, "invalid/bad_yaml.skill.md")
      assert {:error, %YamlElixir.ParsingError{}} = Parser.load_file(path)
    end

    test "returns {:error, :enoent} for nonexistent file" do
      assert {:error, :enoent} = Parser.load_file("nonexistent/path.skill.md")
    end
  end

  # ---------------------------------------------------------------------------
  # load_file/1 — name format validation
  # ---------------------------------------------------------------------------

  describe "load_file/1 name format validation" do
    test "accepts bare name without colon" do
      content = """
      ---
      name: "bash"
      description: "A bare-named skill"
      ---
      Body text.
      """

      path = write_tmp_fixture("bare_name.skill.md", content)
      assert {:ok, %SkillKit.Skill{name: "bash", namespace: "bash"}} = Parser.load_file(path)
    end

    test "returns {:error, :invalid_name_format} for name with empty namespace" do
      content = """
      ---
      name: ":skill-name"
      description: "Empty namespace"
      ---
      Body.
      """

      path = write_tmp_fixture("empty_ns.skill.md", content)
      assert {:error, :invalid_name_format} = Parser.load_file(path)
    end

    test "returns {:error, :invalid_name_format} for name with empty skill part" do
      content = """
      ---
      name: "namespace:"
      description: "Empty skill name"
      ---
      Body.
      """

      path = write_tmp_fixture("empty_skill.skill.md", content)
      assert {:error, :invalid_name_format} = Parser.load_file(path)
    end
  end

  # ---------------------------------------------------------------------------
  # load_file/1 — required_scope field handling
  # ---------------------------------------------------------------------------

  describe "load_file/1 required_scope field" do
    test "defaults to [] when required_scope not present in frontmatter" do
      content = """
      ---
      name: "tools:test"
      description: "No scope field"
      ---
      Body without scope.
      """

      path = write_tmp_fixture("no_scope.skill.md", content)
      assert {:ok, skill} = Parser.load_file(path)
      assert skill.required_scope == []
    end

    test "accepts a list of strings for required_scope" do
      content = """
      ---
      name: "tools:test"
      description: "Multi scope"
      required_scope:
        - "tools:read"
        - "tools:write"
      ---
      Body.
      """

      path = write_tmp_fixture("multi_scope.skill.md", content)
      assert {:ok, skill} = Parser.load_file(path)
      assert skill.required_scope == ["tools:read", "tools:write"]
    end

    test "coerces single string required_scope to a list" do
      content = """
      ---
      name: "tools:test"
      description: "Single scope as string"
      required_scope: "single:scope"
      ---
      Body.
      """

      path = write_tmp_fixture("single_scope.skill.md", content)
      assert {:ok, skill} = Parser.load_file(path)
      assert skill.required_scope == ["single:scope"]
    end
  end

  # ---------------------------------------------------------------------------
  # atoms: false verification
  # ---------------------------------------------------------------------------

  describe "atoms: false YAML parsing" do
    test "skill struct fields are all binary strings (not atoms)" do
      path = Path.join(@fixtures_path, "valid/summarize.skill.md")
      {:ok, skill} = Parser.load_file(path)
      # These are struct fields — verify the values loaded from YAML are binaries
      assert is_binary(skill.name)
      assert is_binary(skill.description)
      assert is_binary(skill.namespace)
      assert Enum.all?(skill.required_scope, &is_binary/1)
    end

    test "required_scope list contains binary strings (not atoms)" do
      path = Path.join(@fixtures_path, "valid/summarize.skill.md")
      {:ok, skill} = Parser.load_file(path)
      assert skill.required_scope == ["files:read"]
      # Verify they are binaries, not atoms
      assert Enum.all?(skill.required_scope, fn s -> is_binary(s) end)
    end
  end

  # ---------------------------------------------------------------------------
  # load_file/1 — missing required fields
  # ---------------------------------------------------------------------------

  describe "load_file/1 missing required field errors" do
    test "returns {:error, {:missing_field, \"description\"}} when description absent" do
      content = """
      ---
      name: "tools:test"
      ---
      Body without description.
      """

      path = write_tmp_fixture("missing_desc.skill.md", content)
      assert {:error, {:missing_field, "description"}} = Parser.load_file(path)
    end

    test "returns {:error, {:missing_field, \"name\"}} when name is empty string" do
      content = """
      ---
      name: ""
      description: "Some description"
      ---
      Body.
      """

      path = write_tmp_fixture("empty_name.skill.md", content)
      assert {:error, {:missing_field, "name"}} = Parser.load_file(path)
    end
  end

  # ---------------------------------------------------------------------------
  # load_file/1 — hook YAML parsing
  # ---------------------------------------------------------------------------

  describe "load_file/1 with hooks in frontmatter" do
    test "parses PreToolUse hooks into %Hook{} structs" do
      content = """
      ---
      name: "secure:check"
      description: "Security checker"
      hooks:
        PreToolUse:
          - matcher: "Shell"
            hooks:
              - type: command
                command: "./scripts/check.sh"
      ---
      Check things.
      """

      path = write_tmp_fixture("with_hooks.skill.md", content)
      assert {:ok, %Skill{} = skill} = Parser.load_file(path)
      assert length(skill.hooks) == 1

      [hook] = skill.hooks
      assert hook.phase == :pre
      assert Regex.match?(hook.matcher, "Shell")
    end

    test "parses PostToolUse hooks" do
      content = """
      ---
      name: "audit:log"
      description: "Audit logger"
      hooks:
        PostToolUse:
          - matcher: ".*"
            hooks:
              - type: command
                command: "./scripts/audit.sh"
      ---
      Log everything.
      """

      path = write_tmp_fixture("post_hooks.skill.md", content)
      assert {:ok, %Skill{} = skill} = Parser.load_file(path)
      assert length(skill.hooks) == 1

      [hook] = skill.hooks
      assert hook.phase == :post
    end

    test "skills without hooks have empty hooks list" do
      path = Path.join(@fixtures_path, "valid/summarize.skill.md")
      assert {:ok, %Skill{hooks: []}} = Parser.load_file(path)
    end
  end

  # ---------------------------------------------------------------------------
  # load_file/1 — metadata field
  # ---------------------------------------------------------------------------

  describe "load_file/1 metadata field" do
    test "parses metadata from frontmatter" do
      path = Path.join(@valid_path, "metadata.skill.md")
      assert {:ok, skill} = Parser.load_file(path)
      assert skill.metadata["author"] == "test-org"
      assert skill.metadata["version"] == "1.0"
    end

    test "defaults metadata to empty map when not present" do
      path = Path.join(@valid_path, "summarize.skill.md")
      assert {:ok, skill} = Parser.load_file(path)
      assert skill.metadata == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Helper: write temporary fixture file
  # ---------------------------------------------------------------------------

  defp write_tmp_fixture(filename, content) do
    tmp_dir = System.tmp_dir!()
    path = Path.join(tmp_dir, "skill_kit_test_#{:erlang.unique_integer([:positive])}_#{filename}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
