defmodule SkillKit.Web.OnboardingTest do
  use ExUnit.Case, async: true

  alias SkillKit.Web.OnboardingKit.Onboarding

  describe "parse_response/1" do
    test "parses full three-line format" do
      content = """
      Who will use this?
      > Think about your primary audience
      e.g. small business owners
      """

      assert %{
               question: "Who will use this?",
               subtext: "Think about your primary audience",
               placeholder: "e.g. small business owners"
             } = Onboarding.parse_response(content)
    end

    test "parses question with subtext only" do
      content = """
      What problem does it solve?
      > Focus on the core pain point
      """

      assert %{
               question: "What problem does it solve?",
               subtext: "Focus on the core pain point",
               placeholder: nil
             } = Onboarding.parse_response(content)
    end

    test "parses plain question without hints" do
      assert %{
               question: "How many users?",
               subtext: nil,
               placeholder: nil
             } = Onboarding.parse_response("How many users?")
    end

    test "uses first extra line as subtext when no > marker" do
      content = """
      What's the name?
      A short working title is fine
      """

      assert %{
               question: "What's the name?",
               subtext: "A short working title is fine",
               placeholder: nil
             } = Onboarding.parse_response(content)
    end

    test "handles nil content" do
      assert %{question: "", subtext: nil, placeholder: nil} =
               Onboarding.parse_response(nil)
    end

    test "handles empty content" do
      assert %{question: "", subtext: nil, placeholder: nil} =
               Onboarding.parse_response("")
    end
  end

  describe "fixed_questions/0" do
    test "returns a list of question maps" do
      questions = Onboarding.fixed_questions()
      assert length(questions) >= 2

      for q <- questions do
        assert is_binary(q.question)
        assert is_binary(q.subtext)
        assert is_binary(q.placeholder)
      end
    end
  end

  describe "format_pairs_message/1" do
    test "formats Q&A pairs" do
      pairs = [
        %{question: "What does it do?", answer: "tracks inventory"},
        %{question: "Name?", answer: "Stockpile"}
      ]

      message = Onboarding.format_pairs_message(pairs)
      assert message =~ "What does it do?"
      assert message =~ "tracks inventory"
      assert message =~ "Name?"
      assert message =~ "Stockpile"
    end
  end
end
