defmodule SkillKit.Eval.ResultTest do
  use ExUnit.Case, async: true

  alias SkillKit.Eval
  alias SkillKit.Eval.Check
  alias SkillKit.Eval.Result
  alias SkillKit.Eval.Transcript

  defp result(checks, transcript) do
    %Result{
      eval: %Eval{name: "greets by name", prompt: "Hi, I'm Sam", rubric: "Greets by name."},
      transcript: transcript,
      checks: checks
    }
  end

  test "failure_message shows the judge verdict and the captured transcript" do
    transcript = %Transcript{status: :ok, response: "1. Missing nil guard", tool_calls: ["bash"]}

    checks = [
      Check.pass("agent completed"),
      Check.fail("llm-judge: rubric satisfied", "VERDICT: FAIL\n\nInvented issues.")
    ]

    message = Result.failure_message(result(checks, transcript))

    assert message =~ "failed 1/2 checks"
    assert message =~ "✗ llm-judge: rubric satisfied"
    assert message =~ "VERDICT: FAIL"
    assert message =~ "Invented issues."
    assert message =~ "── transcript ──"
    assert message =~ "Hi, I'm Sam"
    assert message =~ "tools called: bash"
    assert message =~ "response:"
    assert message =~ "Missing nil guard"
    # passing checks are not listed
    refute message =~ "agent completed"
  end

  test "failure_message reports an errored run instead of a response" do
    transcript = %Transcript{status: :error, error: :boom}
    checks = [Check.fail("agent completed", "agent errored: :boom")]

    message = Result.failure_message(result(checks, transcript))

    assert message =~ "tools called: (none)"
    assert message =~ "error: :boom"
    refute message =~ "response:"
  end
end
