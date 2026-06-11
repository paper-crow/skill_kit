defmodule SkillKit.Eval.ExpectationTest do
  use ExUnit.Case, async: true

  alias SkillKit.Eval
  alias SkillKit.Eval.Expectation
  alias SkillKit.Eval.Transcript

  defp ok(response, tool_calls \\ []) do
    %Transcript{response: response, tool_calls: tool_calls, status: :ok}
  end

  defp passed?(checks, name) do
    Enum.find_value(checks, fn check ->
      if check.name == name, do: check.passed
    end)
  end

  test "passes when the response contains every expected substring" do
    eval = %Eval{name: "e", expect_response: ["Hello", "Sam"]}
    checks = Expectation.evaluate(eval, ok("Hello there, Sam!"))

    assert passed?(checks, "response contains \"Hello\"")
    assert passed?(checks, "response contains \"Sam\"")
  end

  test "fails the substring check when the response is missing it" do
    eval = %Eval{name: "e", expect_response: ["Goodbye"]}
    checks = Expectation.evaluate(eval, ok("Hello there"))

    refute passed?(checks, "response contains \"Goodbye\"")
  end

  test "refute checks fail when the forbidden substring is present" do
    eval = %Eval{name: "e", refute_response: ["error"]}
    checks = Expectation.evaluate(eval, ok("an error occurred"))

    refute passed?(checks, "response excludes \"error\"")
  end

  test "refute checks pass when the forbidden substring is absent" do
    eval = %Eval{name: "e", refute_response: ["error"]}
    checks = Expectation.evaluate(eval, ok("all good"))

    assert passed?(checks, "response excludes \"error\"")
  end

  test "tool checks pass only when the named tool was called" do
    eval = %Eval{name: "e", expect_tools: ["bash"]}

    assert passed?(Expectation.evaluate(eval, ok("done", ["bash"])), "calls tool \"bash\"")
    refute passed?(Expectation.evaluate(eval, ok("done", ["read"])), "calls tool \"bash\"")
  end

  test "an errored run fails the completion check" do
    eval = %Eval{name: "e"}
    transcript = %Transcript{status: :error, error: :boom}
    checks = Expectation.evaluate(eval, transcript)

    refute passed?(checks, "agent completed")
  end

  test "a timed-out run fails the completion check" do
    eval = %Eval{name: "e"}
    checks = Expectation.evaluate(eval, %Transcript{status: :timeout})

    refute passed?(checks, "agent completed")
  end

  test "a successful run adds no completion check" do
    eval = %Eval{name: "e"}
    checks = Expectation.evaluate(eval, ok("hi"))

    assert Enum.all?(checks, &(&1.name != "agent completed"))
  end
end
