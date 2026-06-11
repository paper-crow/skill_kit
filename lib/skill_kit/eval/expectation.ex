defmodule SkillKit.Eval.Expectation do
  @moduledoc """
  Scores an eval's deterministic expectations against a transcript.

  Pure and side-effect free: given an `%SkillKit.Eval{}` and an
  `%SkillKit.Eval.Transcript{}`, it returns the list of
  `%SkillKit.Eval.Check{}` for the run's terminal status and each declared
  `expect` clause. The LLM-judge check is added separately by
  `SkillKit.Eval.Runner`.
  """

  alias SkillKit.Eval
  alias SkillKit.Eval.Check
  alias SkillKit.Eval.Transcript

  @doc """
  Returns the deterministic checks for `eval` given `transcript`.
  """
  @spec evaluate(Eval.t(), Transcript.t()) :: [Check.t()]
  def evaluate(%Eval{} = eval, %Transcript{} = transcript) do
    status_checks(transcript) ++
      response_checks(eval.expect_response, transcript.response) ++
      refute_checks(eval.refute_response, transcript.response) ++
      tool_checks(eval.expect_tools, transcript.tool_calls)
  end

  # --- Terminal status ---

  defp status_checks(%Transcript{status: :ok}), do: []

  defp status_checks(%Transcript{status: :error, error: reason}) do
    [Check.fail("agent completed", "agent errored: #{inspect(reason)}")]
  end

  defp status_checks(%Transcript{status: :timeout}) do
    [Check.fail("agent completed", "agent timed out before responding")]
  end

  defp status_checks(%Transcript{status: :pending}) do
    [Check.fail("agent completed", "agent produced no response")]
  end

  # --- response contains ---

  defp response_checks(needles, response) do
    Enum.map(needles, &response_contains_check(&1, response))
  end

  defp response_contains_check(needle, response) do
    name = "response contains #{inspect(needle)}"
    Check.new(name, contains?(response, needle), response_detail(response))
  end

  # --- response must not contain ---

  defp refute_checks(needles, response) do
    Enum.map(needles, &response_excludes_check(&1, response))
  end

  defp response_excludes_check(needle, response) do
    name = "response excludes #{inspect(needle)}"
    Check.new(name, not contains?(response, needle), response_detail(response))
  end

  # --- tool calls ---

  defp tool_checks(names, tool_calls) do
    Enum.map(names, &tool_called_check(&1, tool_calls))
  end

  defp tool_called_check(name, tool_calls) do
    check_name = "calls tool #{inspect(name)}"
    detail = "tools called: #{inspect(tool_calls)}"
    Check.new(check_name, name in tool_calls, detail)
  end

  # --- helpers ---

  defp contains?(nil, _needle), do: false
  defp contains?(response, needle), do: String.contains?(response, needle)

  defp response_detail(nil), do: "response: (none)"
  defp response_detail(response), do: "response: #{inspect(response)}"
end
