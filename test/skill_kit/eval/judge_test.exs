defmodule SkillKit.Eval.JudgeTest do
  use ExUnit.Case, async: true

  import Mox

  alias SkillKit.Eval.Judge
  alias SkillKit.Eval.Transcript
  alias SkillKit.Response.Text

  setup :verify_on_exit!

  @rubric "Greets the user by name."
  @transcript %Transcript{response: "Hello, Sam!", tool_calls: [], status: :ok}

  test "returns {:pass, reasoning, nil} when the judge votes PASS with no warning" do
    SkillKit.Test.expect_response(%Text{content: "VERDICT: PASS — warm and named."})

    assert {{:pass, reasoning, nil}, _usage} = Judge.judge(@rubric, @transcript)
    assert reasoning =~ "PASS"
  end

  test "passes with a warning, extracting the WARNING line" do
    SkillKit.Test.expect_response(%Text{
      content: "VERDICT: PASS\nWARNING: did not repeat the name\nGood enough."
    })

    assert {{:pass, reasoning, "did not repeat the name"}, _usage} =
             Judge.judge(@rubric, @transcript)

    assert reasoning =~ "PASS"
  end

  test "returns {:fail, reasoning} when the judge votes FAIL" do
    SkillKit.Test.expect_response(%Text{content: "VERDICT: FAIL — never used the name."})

    assert {{:fail, reasoning}, _usage} = Judge.judge(@rubric, @transcript)
    assert reasoning =~ "FAIL"
  end

  test "a FAIL verdict wins over a PASS line that also appears" do
    SkillKit.Test.expect_response(%Text{
      content: "VERDICT: FAIL\nSecurity hole. (I first wrote VERDICT: PASS, then reconsidered.)"
    })

    assert {{:fail, _reasoning}, _usage} = Judge.judge(@rubric, @transcript)
  end

  test "treats a missing verdict as a failure" do
    SkillKit.Test.expect_response(%Text{content: "I am not sure how to score this."})

    assert {{:fail, reasoning}, _usage} = Judge.judge(@rubric, @transcript)
    assert reasoning =~ "no verdict"
  end

  test "surfaces LLM errors as {:error, reason} with empty usage" do
    SkillKit.Test.expect_error(500, "boom")

    assert {{:error, {500, "boom"}}, usage} = Judge.judge(@rubric, @transcript)
    assert usage.input_tokens == 0
    assert usage.output_tokens == 0
  end

  test "returns the judge's own token usage alongside the verdict" do
    Mox.expect(SkillKit.LLM.Mock, :stream, fn _messages, _opts ->
      events = [
        %SkillKit.Event.Delta{text: "VERDICT: PASS"},
        %SkillKit.Event.Usage{input_tokens: 50, output_tokens: 10},
        %SkillKit.Event.Done{stop_reason: :end_turn}
      ]

      {:ok, Stream.map(events, & &1)}
    end)

    assert {{:pass, _reasoning, nil}, usage} = Judge.judge(@rubric, @transcript)
    assert usage.input_tokens == 50
    assert usage.output_tokens == 10
  end

  test "includes the user prompt as judge context" do
    SkillKit.Test.assert_response(%Text{content: "VERDICT: PASS"}, fn [message], _opts ->
      assert message.content =~ "Hi, I'm Sam"
    end)

    assert {{:pass, _reasoning, _warning}, _usage} =
             Judge.judge(@rubric, @transcript, prompt: "Hi, I'm Sam")
  end
end
