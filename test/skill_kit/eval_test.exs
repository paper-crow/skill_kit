defmodule SkillKit.EvalTest do
  use ExUnit.Case, async: true

  alias SkillKit.Eval

  @fixtures Path.expand("../support/fixtures/evals", __DIR__)

  describe "parse/2" do
    test "parses frontmatter wiring and the Prompt/Expect body sections" do
      content = """
      ---
      name: "greets the user"
      description: "warm greeting"
      system: "You are a greeter."
      model: "anthropic:claude-sonnet-4-20250514"
      skills:
        - "skills/greeter"
      tools:
        - "SkillKit.Tools.Shell"
      ---
      ## Prompt
      Hi, I'm Sam

      ## Expect
      Greets the user by name in a friendly tone.
      """

      assert {:ok, eval} = Eval.parse(content, "EVAL.md")
      assert eval.name == "greets the user"
      assert eval.description == "warm greeting"
      assert eval.system == "You are a greeter."
      assert eval.model == "anthropic:claude-sonnet-4-20250514"
      assert eval.prompt == "Hi, I'm Sam"
      assert eval.rubric == "Greets the user by name in a friendly tone."
      assert eval.location == "EVAL.md"
      assert eval.skills == ["skills/greeter"]
      assert eval.tools == [SkillKit.Tools.Shell]
    end

    test "matches section headings case-insensitively at any level" do
      content = """
      ---
      name: "case"
      ---
      ### prompt
      go

      # EXPECT
      done
      """

      assert {:ok, eval} = Eval.parse(content)
      assert eval.prompt == "go"
      assert eval.rubric == "done"
    end

    test "keeps `#`-prefixed lines inside a section as content" do
      content = """
      ---
      name: "hashes"
      ---
      ## Prompt
      Run this:
      # not a heading
      echo hi

      ## Expect
      Runs the command.
      """

      assert {:ok, eval} = Eval.parse(content)
      assert eval.prompt == "Run this:\n# not a heading\necho hi"
    end

    test "resolves module-name providers to atoms and paths to strings" do
      content = """
      ---
      name: "providers"
      skills:
        - "skills/local"
      tools:
        - "SkillKit.Tools.Shell"
      ---
      ## Prompt
      go

      ## Expect
      done
      """

      assert {:ok, eval} = Eval.parse(content)
      assert eval.skills == ["skills/local"]
      assert eval.tools == [SkillKit.Tools.Shell]
    end

    test "requires name" do
      content = "---\ndesc: x\n---\n## Prompt\ngo\n\n## Expect\ndone\n"
      assert {:error, {:missing_field, "name"}} = Eval.parse(content)
    end

    test "requires a Prompt section" do
      content = "---\nname: x\n---\n## Expect\ndone\n"
      assert {:error, {:missing_section, "prompt"}} = Eval.parse(content)
    end

    test "requires an Expect section" do
      content = "---\nname: x\n---\n## Prompt\ngo\n"
      assert {:error, {:missing_section, "expect"}} = Eval.parse(content)
    end
  end

  describe "load_dir/1" do
    test "discovers EVAL.md and *.eval.md files, sorted by path" do
      assert {:ok, evals} = Eval.load_dir(@fixtures)
      names = Enum.map(evals, & &1.name)
      assert "greets the user by name" in names
      assert "runs a shell command" in names
    end

    test "returns the locations of the loaded files" do
      assert {:ok, evals} = Eval.load_dir(@fixtures)
      assert Enum.all?(evals, &is_binary(&1.location))
    end
  end

  describe "load_dir!/1" do
    test "returns the evals directly" do
      evals = Eval.load_dir!(@fixtures)
      assert length(evals) == 2
    end
  end
end
