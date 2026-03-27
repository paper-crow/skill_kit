defmodule SkillKit.Kit.Local.ParserTest do
  use ExUnit.Case, async: true

  alias SkillKit.Hook
  alias SkillKit.Kit.Local.Parser
  alias SkillKit.Skill

  @fixtures_path Path.join([__DIR__, "..", "..", "..", "support", "fixtures", "skills"])
  @valid_path Path.join([__DIR__, "..", "..", "..", "support", "fixtures", "skills", "valid"])

  # ---------------------------------------------------------------------------
  # load_file/1 — valid files
  # ---------------------------------------------------------------------------

  describe "load_file/1 with valid files" do
    test "returns {:ok, %Skill{}} for summarize SKILL.md — full round-trip" do
      path = Path.join(@fixtures_path, "valid/skills/summarize/SKILL.md")
      assert {:ok, %Skill{} = skill} = Parser.load_file(path)
      assert skill.name == "files:summarize"
      assert skill.namespace == "files"
      assert skill.description == "Summarize a file's contents"
      assert skill.required_scope == ["files:read"]
      assert skill.location == path
      assert skill.tool == SkillKit.Tools.Shell
      assert skill.hooks == []
      assert String.contains?(skill.body, "{{content}}")
    end

    test "returns {:ok, %Skill{}} for multi-arg SKILL.md — multiple template vars" do
      path = Path.join(@fixtures_path, "valid/skills/multi-arg/SKILL.md")
      assert {:ok, %Skill{} = skill} = Parser.load_file(path)
      assert skill.name == "tools:multi-arg"
      assert skill.description == "Test multiple arguments"
      assert String.contains?(skill.body, "$0")
      assert String.contains?(skill.body, "$1")
    end

    test "body has leading/trailing whitespace trimmed" do
      path = Path.join(@fixtures_path, "valid/skills/summarize/SKILL.md")
      {:ok, skill} = Parser.load_file(path)
      assert skill.body == String.trim(skill.body)
    end

    test "required_scope is a list of strings for summarize fixture" do
      path = Path.join(@fixtures_path, "valid/skills/summarize/SKILL.md")
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
      path = Path.join(@fixtures_path, "invalid/skills/missing-name/SKILL.md")
      assert {:error, {:missing_field, "name"}} = Parser.load_file(path)
    end

    test "returns {:error, %YamlElixir.ParsingError{}} for invalid YAML" do
      path = Path.join(@fixtures_path, "invalid/skills/bad-yaml/SKILL.md")
      assert {:error, %YamlElixir.ParsingError{}} = Parser.load_file(path)
    end

    test "returns {:error, :enoent} for nonexistent file" do
      assert {:error, :enoent} = Parser.load_file("nonexistent/path.md")
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

      path = write_tmp_fixture("bare_name.md", content)
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

      path = write_tmp_fixture("empty_ns.md", content)
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

      path = write_tmp_fixture("empty_skill.md", content)
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

      path = write_tmp_fixture("no_scope.md", content)
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

      path = write_tmp_fixture("multi_scope.md", content)
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

      path = write_tmp_fixture("single_scope.md", content)
      assert {:ok, skill} = Parser.load_file(path)
      assert skill.required_scope == ["single:scope"]
    end
  end

  # ---------------------------------------------------------------------------
  # atoms: false verification
  # ---------------------------------------------------------------------------

  describe "atoms: false YAML parsing" do
    test "skill struct fields are all binary strings (not atoms)" do
      path = Path.join(@fixtures_path, "valid/skills/summarize/SKILL.md")
      {:ok, skill} = Parser.load_file(path)
      # These are struct fields — verify the values loaded from YAML are binaries
      assert is_binary(skill.name)
      assert is_binary(skill.description)
      assert is_binary(skill.namespace)
      assert Enum.all?(skill.required_scope, &is_binary/1)
    end

    test "required_scope list contains binary strings (not atoms)" do
      path = Path.join(@fixtures_path, "valid/skills/summarize/SKILL.md")
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

      path = write_tmp_fixture("missing_desc.md", content)
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

      path = write_tmp_fixture("empty_name.md", content)
      assert {:error, {:missing_field, "name"}} = Parser.load_file(path)
    end
  end

  # ---------------------------------------------------------------------------
  # load_file/1 — hook YAML parsing
  # ---------------------------------------------------------------------------

  describe "load_file/1 with hooks in frontmatter" do
    test "parses PreToolUse hooks — event atom and matcher regex" do
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

      path = write_tmp_fixture("with_hooks.md", content)
      assert {:ok, %Skill{} = skill} = Parser.load_file(path)
      assert length(skill.hooks) == 1

      [hook] = skill.hooks
      assert hook.event == :pre_tool_use
      assert Regex.match?(hook.matcher, "Shell")
    end

    test "parses PostToolUse hooks — event atom" do
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

      path = write_tmp_fixture("post_hooks.md", content)
      assert {:ok, %Skill{} = skill} = Parser.load_file(path)
      assert length(skill.hooks) == 1

      [hook] = skill.hooks
      assert hook.event == :post_tool_use
    end

    test "handler type 'command' resolves to {SkillKit.Hooks.Command, config}" do
      content = """
      ---
      name: "tools:guarded"
      description: "Guarded tool"
      hooks:
        PreToolUse:
          - hooks:
              - type: command
                command: "./scripts/guard.sh"
      ---
      Body.
      """

      path = write_tmp_fixture("command_handler.md", content)
      assert {:ok, %Skill{} = skill} = Parser.load_file(path)
      [hook] = skill.hooks
      assert {SkillKit.Hooks.Command, %{"command" => "./scripts/guard.sh"}} = hook.handler
    end

    test "nil matcher when no matcher specified" do
      content = """
      ---
      name: "tools:no-matcher"
      description: "No matcher"
      hooks:
        PreToolUse:
          - hooks:
              - type: command
                command: "./scripts/run.sh"
      ---
      Body.
      """

      path = write_tmp_fixture("no_matcher.md", content)
      assert {:ok, %Skill{} = skill} = Parser.load_file(path)
      [hook] = skill.hooks
      assert hook.matcher == nil
    end

    test "unknown event names produce no hooks" do
      content = """
      ---
      name: "tools:unknown"
      description: "Unknown event"
      hooks:
        UnknownEvent:
          - matcher: ".*"
            hooks:
              - type: command
                command: "./scripts/run.sh"
      ---
      Body.
      """

      path = write_tmp_fixture("unknown_event.md", content)
      assert {:ok, %Skill{hooks: []}} = Parser.load_file(path)
    end

    test "skills without hooks have empty hooks list" do
      path = Path.join(@fixtures_path, "valid/skills/summarize/SKILL.md")
      assert {:ok, %Skill{hooks: []}} = Parser.load_file(path)
    end

    test "all 16 event names in @event_map map to correct atoms" do
      event_pairs = [
        {"PreToolUse", :pre_tool_use},
        {"PostToolUse", :post_tool_use},
        {"PreSubagent", :pre_subagent},
        {"PostSubagent", :post_subagent},
        {"PreSkillActivation", :pre_skill_activation},
        {"PostSkillActivation", :post_skill_activation},
        {"PreConversationSave", :pre_conversation_save},
        {"PostConversationSave", :post_conversation_save},
        {"PreConversationLoad", :pre_conversation_load},
        {"PostConversationLoad", :post_conversation_load},
        {"PreLlmRequest", :pre_llm_request},
        {"PostLlmRequest", :post_llm_request},
        {"PreTurn", :pre_turn},
        {"PostTurn", :post_turn},
        {"PreAgent", :pre_agent},
        {"PostAgent", :post_agent}
      ]

      Enum.each(event_pairs, fn {yaml_name, expected_atom} ->
        content = """
        ---
        name: "tools:test"
        description: "Event test"
        hooks:
          #{yaml_name}:
            - hooks:
                - type: command
                  command: "./scripts/run.sh"
        ---
        Body.
        """

        path = write_tmp_fixture("event_#{yaml_name}.md", content)
        assert {:ok, %Skill{} = skill} = Parser.load_file(path)
        assert length(skill.hooks) == 1
        [%Hook{event: event}] = skill.hooks

        assert event == expected_atom,
               "Expected #{yaml_name} → #{expected_atom}, got #{inspect(event)}"
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # load_file/1 — metadata field
  # ---------------------------------------------------------------------------

  describe "load_file/1 metadata field" do
    test "parses metadata from frontmatter" do
      path = Path.join(@valid_path, "skills/metadata/SKILL.md")
      assert {:ok, skill} = Parser.load_file(path)
      assert skill.metadata["version"] == "1.0"
    end

    test "defaults metadata to empty map when not present" do
      path = Path.join(@valid_path, "skills/summarize/SKILL.md")
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
