defmodule SkillKit.Web.Onboarding do
  @moduledoc """
  Domain logic for the onboarding flow.

  Owns the fixed question definitions, agent response parsing,
  and message formatting. The LiveView delegates to this module
  for all onboarding-specific logic.
  """

  @fixed_questions [
    %{
      question: "What's the one thing it needs to do?",
      subtext: "Don't overthink it — just the core action.",
      placeholder: "manage inventory for our warehouse"
    },
    %{
      question: "Give it a working name",
      subtext: "You can always change this later.",
      placeholder: "e.g. Stockpile"
    }
  ]

  @doc "Returns the list of fixed onboarding questions."
  def fixed_questions, do: @fixed_questions

  @doc "Returns the number of fixed questions."
  def fixed_question_count, do: length(@fixed_questions)

  @doc "Returns the fixed question at the given index, or nil if out of bounds."
  def fixed_question(index) when index >= 0 and index < length(@fixed_questions) do
    Enum.at(@fixed_questions, index)
  end

  def fixed_question(_index), do: nil

  @doc """
  Parses an agent's text response into a structured question map.

  The agent is instructed to format responses as:

      What's the question?
      > Helper text for the user
      e.g. an example answer

  Returns `%{question: string, subtext: string | nil, placeholder: string | nil}`.

  If the response doesn't match the expected format, the full text
  is used as the question with no subtext or placeholder.
  """
  def parse_response(nil), do: %{question: "", subtext: nil, placeholder: nil}

  def parse_response(content) do
    lines =
      content
      |> String.trim()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case lines do
      [] ->
        %{question: "", subtext: nil, placeholder: nil}

      [question] ->
        %{question: question, subtext: nil, placeholder: nil}

      [question | rest] ->
        {subtext, placeholder} = extract_hints(rest)
        %{question: question, subtext: subtext, placeholder: placeholder}
    end
  end

  @doc """
  Formats collected Q&A pairs into a message for the agent.
  """
  def format_pairs_message(pairs) do
    answers =
      Enum.map_join(pairs, "\n", fn %{question: q, answer: a} ->
        "Q: #{q}\nA: #{a}"
      end)

    "[Onboarding answers]\n#{answers}"
  end

  # Lines starting with > are subtext, lines starting with e.g. are placeholders
  defp extract_hints(lines) do
    subtext = find_hint(lines, &String.starts_with?(&1, ">"))
    placeholder = find_hint(lines, &String.starts_with?(&1, "e.g."))

    # If no markers, use the first remaining line as subtext
    subtext =
      if is_nil(subtext) and not Enum.empty?(lines) do
        hd(lines)
      else
        subtext
      end

    {subtext, placeholder}
  end

  defp find_hint(lines, matcher) do
    case Enum.find(lines, matcher) do
      nil -> nil
      line -> String.trim_leading(line, "> ") |> String.trim()
    end
  end
end
