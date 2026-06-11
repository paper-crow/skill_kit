defmodule SkillKit.EvalTest do
  use ExUnit.Case, async: true

  alias SkillKit.Eval

  @fixtures Path.expand("../support/fixtures/evals", __DIR__)

  describe "parse/2" do
    test "parses frontmatter, expectations, and the body as the rubric" do
      content = """
      ---
      name: "greets the user"
      description: "warm greeting"
      system: "You are a greeter."
      model: "anthropic:claude-sonnet-4-20250514"
      prompt: "Hi, I'm Sam"
      skills:
        - "test/fixtures/greeter"
      tools:
        - "SkillKit.Tools.Shell"
      expect:
        response: ["Sam"]
        not_response: ["error"]
        tools: ["bash"]
      ---
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
      assert eval.expect_response == ["Sam"]
      assert eval.refute_response == ["error"]
      assert eval.expect_tools == ["bash"]
    end

    test "resolves module-name providers to atoms and paths to strings" do
      content = """
      ---
      name: "providers"
      prompt: "go"
      skills:
        - "skills/local"
      tools:
        - "SkillKit.Tools.Shell"
      ---
      """

      assert {:ok, eval} = Eval.parse(content)
      assert eval.skills == ["skills/local"]
      assert eval.tools == [SkillKit.Tools.Shell]
    end

    test "an empty body yields a nil rubric" do
      content = """
      ---
      name: "no rubric"
      prompt: "go"
      ---
      """

      assert {:ok, eval} = Eval.parse(content)
      assert eval.rubric == nil
    end

    test "coerces a single scalar expectation into a list" do
      content = """
      ---
      name: "scalar"
      prompt: "go"
      expect:
        response: "ok"
      ---
      """

      assert {:ok, eval} = Eval.parse(content)
      assert eval.expect_response == ["ok"]
    end

    test "requires name and prompt" do
      assert {:error, {:missing_field, "name"}} = Eval.parse("---\nprompt: \"x\"\n---\n")
      assert {:error, {:missing_field, "prompt"}} = Eval.parse("---\nname: \"x\"\n---\n")
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
