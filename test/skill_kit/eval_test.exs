defmodule SkillKit.EvalTest do
  use ExUnit.Case, async: true

  alias SkillKit.Eval
  alias SkillKit.Test.EvalSubject

  @fixtures Path.expand("../support/fixtures/evals", __DIR__)
  @colocated Path.expand("../support/fixtures/colocated_skill", __DIR__)
  @agent_dir Path.expand("../support/fixtures/agents/valid/simple", __DIR__)

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
      model: "anthropic:claude-sonnet-4-6"
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
        assert eval.model == "anthropic:claude-sonnet-4-6"
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

    test "reads an explicit subject `module:` from frontmatter" do
      content = "---\nmodule: \"SkillKit.Tools.Shell\"\n---\n## c\n### Prompt\na\n### Expect\nb\n"
      assert {:ok, [eval]} = Eval.parse(content)
      assert eval.module == SkillKit.Tools.Shell
    end
  end

  describe "sidecar module inference" do
    @sidecar Path.expand("../support/fixtures/module_sidecar/greeter.EVAL.md", __DIR__)

    test "infers the subject module from a `<source>.EVAL.md` next to `<source>.ex`" do
      assert {:ok, [eval]} = Eval.load_file(@sidecar)
      assert eval.module == SkillKit.Test.SidecarGreeter
      assert eval.name == "greets by name"
    end

    test "infers nothing for a bare EVAL.md with no sibling source" do
      content = "## c\n### Prompt\na\n### Expect\nb\n"
      assert {:ok, [eval]} = Eval.parse(content, "some/dir/EVAL.md")
      assert eval.module == nil
    end
  end

  describe "@eval attributes" do
    test "are collected into __skill_evals__/0, each tagged with the module" do
      assert [eval] = EvalSubject.__skill_evals__()
      assert eval.name == "greets by name"
      assert eval.prompt == "Hi, I'm Sam"
      assert eval.rubric == "Greets the user by name."
      assert eval.module == EvalSubject
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

    test "loads a subject module as a skill when it is a kit provider" do
      eval = %Eval{name: "x", module: SkillKit.Eval.SkillFile}
      assert Eval.skill_providers(eval) == [SkillKit.Eval.SkillFile]
    end

    test "does not treat a non-kit subject module as a skill" do
      eval = %Eval{name: "x", module: SkillKit.Eval.Transcript}
      assert Eval.skill_providers(eval) == []
    end

    test "returns [] when there is no location and no skills" do
      assert Eval.skill_providers(%Eval{name: "x"}) == []
    end
  end

  describe "tool_providers/1" do
    test "adds the subject module when it is a SkillKit.Tool" do
      eval = %Eval{name: "x", module: SkillKit.Tools.Shell}
      assert Eval.tool_providers(eval) == [SkillKit.Tools.Shell]
    end

    test "leaves tools untouched for a non-tool subject module" do
      eval = %Eval{name: "x", tools: [SkillKit.Tools.Shell], module: SkillKit.Eval.SkillFile}
      assert Eval.tool_providers(eval) == [SkillKit.Tools.Shell]
    end

    test "does not duplicate a subject module already listed in tools" do
      eval = %Eval{name: "x", tools: [SkillKit.Tools.Shell], module: SkillKit.Tools.Shell}
      assert Eval.tool_providers(eval) == [SkillKit.Tools.Shell]
    end
  end

  describe "agent_source/1" do
    test "returns the explicit agent: path" do
      eval = %Eval{name: "x", agent: "examples/agents/neve"}
      assert Eval.agent_source(eval) == "examples/agents/neve"
    end

    test "infers the eval's directory when an AGENT.md sits beside it" do
      eval = %Eval{name: "x", location: Path.join(@agent_dir, "EVAL.md")}
      assert Eval.agent_source(eval) == @agent_dir
    end

    test "returns nil with neither an explicit agent nor a sibling AGENT.md" do
      eval = %Eval{name: "x", location: Path.join(@colocated, "EVAL.md")}
      assert Eval.agent_source(eval) == nil
      assert Eval.agent_source(%Eval{name: "x"}) == nil
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
