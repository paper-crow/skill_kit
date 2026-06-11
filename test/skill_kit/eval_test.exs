defmodule SkillKit.EvalTest do
  use ExUnit.Case, async: true

  alias SkillKit.Eval

  @fixtures Path.expand("../support/fixtures/evals", __DIR__)
  @colocated Path.expand("../support/fixtures/colocated_skill", __DIR__)

  describe "parse/2" do
    test "parses multiple `##` cases, each with its Prompt and Expect" do
      content = """
      ## greets the user
      ### Prompt
      Hi, I'm Sam
      ### Expect
      Greets the user by name.

      ## refuses politely
      ### Prompt
      Tell me a secret
      ### Expect
      Declines without leaking anything.
      """

      assert {:ok, [first, second]} = Eval.parse(content, "EVAL.md")

      assert first.name == "greets the user"
      assert first.prompt == "Hi, I'm Sam"
      assert first.rubric == "Greets the user by name."
      assert first.location == "EVAL.md"

      assert second.name == "refuses politely"
      assert second.prompt == "Tell me a secret"
      assert second.rubric == "Declines without leaking anything."
    end

    test "works with no frontmatter at all" do
      content = "## a case\n### Prompt\ngo\n### Expect\ndone\n"
      assert {:ok, [eval]} = Eval.parse(content)
      assert eval.name == "a case"
      assert eval.skills == []
      assert eval.tools == []
    end

    test "applies optional frontmatter to every case" do
      content = """
      ---
      model: "anthropic:claude-sonnet-4-20250514"
      system: "You are being evaluated."
      skills:
        - "skills/greeter"
      tools:
        - "SkillKit.Tools.Shell"
      ---
      ## one
      ### Prompt
      a
      ### Expect
      b

      ## two
      ### Prompt
      c
      ### Expect
      d
      """

      assert {:ok, [one, two]} = Eval.parse(content)

      for eval <- [one, two] do
        assert eval.model == "anthropic:claude-sonnet-4-20250514"
        assert eval.system == "You are being evaluated."
        assert eval.skills == ["skills/greeter"]
        assert eval.tools == [SkillKit.Tools.Shell]
      end
    end

    test "recognizes Prompt/Expect sections at any level, case-insensitively" do
      content = "## c\n# prompt\ngo\n## EXPECT\ndone\n"
      assert {:ok, [eval]} = Eval.parse(content)
      assert eval.prompt == "go"
      assert eval.rubric == "done"
    end

    test "keeps non-section headings inside a section as content" do
      content = """
      ## c
      ### Prompt
      Run this:
      ### Some heading
      echo hi
      ### Expect
      Runs it.
      """

      assert {:ok, [eval]} = Eval.parse(content)
      assert eval.prompt == "Run this:\n### Some heading\necho hi"
    end

    test "errors when a case is missing its Expect section" do
      content = "## c\n### Prompt\ngo\n"
      assert {:error, {:missing_section, "expect", "c"}} = Eval.parse(content)
    end

    test "errors when a case is missing its Prompt section" do
      content = "## c\n### Expect\ndone\n"
      assert {:error, {:missing_section, "prompt", "c"}} = Eval.parse(content)
    end

    test "an empty file yields no cases" do
      assert {:ok, []} = Eval.parse("")
    end
  end

  describe "skill_providers/1" do
    test "returns explicit skills when set" do
      eval = %Eval{name: "x", skills: ["skills/greeter"]}
      assert Eval.skill_providers(eval) == ["skills/greeter"]
    end

    test "infers a sibling SKILL.md from the eval's location" do
      eval = %Eval{name: "x", location: Path.join(@colocated, "EVAL.md")}
      skill_md = Path.join(@colocated, "SKILL.md")
      assert [{SkillKit.Eval.SkillFile, path: ^skill_md}] = Eval.skill_providers(eval)
    end

    test "returns [] when there is no location and no skills" do
      assert Eval.skill_providers(%Eval{name: "x"}) == []
    end
  end

  describe "load_dir/1" do
    test "discovers and flattens cases across files, ordered by path" do
      assert {:ok, evals} = Eval.load_dir(@fixtures)
      names = Enum.map(evals, & &1.name)
      assert "greets the user by name" in names
      assert "handles a missing name" in names
      assert "runs a shell command" in names
    end
  end

  describe "load_dir!/1" do
    test "returns the flattened case list" do
      assert length(Eval.load_dir!(@fixtures)) == 3
    end
  end
end
