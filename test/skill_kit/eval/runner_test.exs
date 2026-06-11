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

  test "passes deterministic expectations against the agent's response" do
    SkillKit.Test.expect_response(%Text{content: "Hello there, Sam!"})

    eval = %Eval{name: "greets", prompt: "Hi, I'm Sam", expect_response: ["Sam"]}
    result = Runner.run(eval)

    assert Result.passed?(result)
    assert result.transcript.response == "Hello there, Sam!"
  end

  test "fails when the response is missing an expected substring" do
    SkillKit.Test.expect_response(%Text{content: "Hello there"})

    eval = %Eval{name: "greets", prompt: "Hi", expect_response: ["Goodbye"]}
    result = Runner.run(eval)

    refute Result.passed?(result)
    assert Enum.any?(Result.failures(result), &(&1.name == "response contains \"Goodbye\""))
  end

  test "runs the LLM judge when the eval has a rubric" do
    SkillKit.Test.expect_responses([
      %Text{content: "Hello, Sam!"},
      %Text{content: "VERDICT: PASS — greeted by name."}
    ])

    eval = %Eval{name: "greets", prompt: "Hi", rubric: "Greets the user by name."}
    result = Runner.run(eval)

    assert Result.passed?(result)
    assert Enum.any?(result.checks, &(&1.name == "llm-judge: rubric satisfied" and &1.passed))
  end

  test "skips the judge when judge: false even with a rubric" do
    SkillKit.Test.expect_response(%Text{content: "Hello, Sam!"})

    eval = %Eval{name: "greets", prompt: "Hi", rubric: "Greets the user by name."}
    result = Runner.run(eval, judge: false)

    assert Result.passed?(result)
    assert Enum.all?(result.checks, &(&1.name != "llm-judge: rubric satisfied"))
  end
end
