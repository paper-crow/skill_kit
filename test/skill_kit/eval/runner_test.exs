defmodule SkillKit.Eval.RunnerTest do
  use ExUnit.Case, async: false

  import Mox

  alias SkillKit.Eval
  alias SkillKit.Eval.Result
  alias SkillKit.Eval.Runner
  alias SkillKit.Response.Text
  alias SkillKit.Storage

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    start_supervised!(Storage.Memory)
    :ok
  end

  defp eval(opts \\ []) do
    %Eval{
      name: "greets",
      prompt: Keyword.get(opts, :prompt, "Hi, I'm Sam"),
      rubric: Keyword.get(opts, :rubric, "Greets the user by name.")
    }
  end

  test "passes when the judge votes PASS" do
    SkillKit.Test.expect_responses([
      %Text{content: "Hello, Sam!"},
      %Text{content: "VERDICT: PASS — greeted by name."}
    ])

    result = Runner.run(eval())

    assert Result.passed?(result)
    assert result.transcript.response == "Hello, Sam!"
    assert Enum.any?(result.checks, &(&1.name == "llm-judge: rubric satisfied" and &1.passed))
  end

  test "fails when the judge votes FAIL" do
    SkillKit.Test.expect_responses([
      %Text{content: "Hello there"},
      %Text{content: "VERDICT: FAIL — never used the name."}
    ])

    result = Runner.run(eval())

    refute Result.passed?(result)
    assert Enum.any?(Result.failures(result), &(&1.name == "llm-judge: rubric satisfied"))
  end

  test "fails the completion check and skips the judge when the agent errors" do
    SkillKit.Test.expect_error(500, "boom")

    result = Runner.run(eval())

    refute Result.passed?(result)
    assert Enum.any?(Result.failures(result), &(&1.name == "agent completed"))
    assert Enum.all?(result.checks, &(&1.name != "llm-judge: rubric satisfied"))
  end

  test "skips the judge when judge: false" do
    SkillKit.Test.expect_response(%Text{content: "Hello, Sam!"})

    result = Runner.run(eval(), judge: false)

    assert Result.passed?(result)
    assert Enum.all?(result.checks, &(&1.name != "llm-judge: rubric satisfied"))
  end
end
