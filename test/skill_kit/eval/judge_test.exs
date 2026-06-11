defmodule SkillKit.Eval.JudgeTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Eval.Judge
  alias SkillKit.Eval.Transcript
  alias SkillKit.Response.Text

  setup :verify_on_exit!

  @rubric "Greets the user by name."
  @transcript %Transcript{response: "Hello, Sam!", tool_calls: [], status: :ok}

  test "returns {:pass, reasoning} when the judge votes PASS" do
    SkillKit.Test.expect_response(%Text{content: "VERDICT: PASS — warm and named."})

    assert {:pass, reasoning} = Judge.judge(@rubric, @transcript)
    assert reasoning =~ "PASS"
  end

  test "returns {:fail, reasoning} when the judge votes FAIL" do
    SkillKit.Test.expect_response(%Text{content: "VERDICT: FAIL — never used the name."})

    assert {:fail, reasoning} = Judge.judge(@rubric, @transcript)
    assert reasoning =~ "FAIL"
  end

  test "treats a missing verdict as a failure" do
    SkillKit.Test.expect_response(%Text{content: "I am not sure how to score this."})

    assert {:fail, reasoning} = Judge.judge(@rubric, @transcript)
    assert reasoning =~ "no verdict"
  end

  test "surfaces LLM errors as {:error, reason}" do
    SkillKit.Test.expect_error(500, "boom")

    assert {:error, {500, "boom"}} = Judge.judge(@rubric, @transcript)
  end

  test "includes the user prompt as judge context" do
    SkillKit.Test.assert_response(%Text{content: "VERDICT: PASS"}, fn [message], _opts ->
      assert message.content =~ "Hi, I'm Sam"
    end)

    assert {:pass, _reasoning} = Judge.judge(@rubric, @transcript, prompt: "Hi, I'm Sam")
  end
end
