defmodule SkillKit.Eval.Judge do
  @moduledoc """
  LLM-as-judge scoring for an eval's natural-language rubric.

  When an eval has a markdown body, the harness asks a model to decide whether
  the agent's transcript satisfies that rubric. The judge is instructed to
  emit a single `VERDICT: PASS` / `VERDICT: FAIL` line followed by a short
  justification; the full text is returned as the reasoning either way.

  The judge calls go through `SkillKit.LLM`, so the configured provider (real
  in `--include eval` runs, the mock in unit tests) decides the verdict.
  """

  alias SkillKit.Eval.Transcript
  alias SkillKit.Event.Delta
  alias SkillKit.Types.UserMessage

  @type verdict :: {:pass | :fail, String.t()} | {:error, term()}

  @doc """
  Scores `transcript` against `rubric`.

  Options:
    * `:model` — model URI for the judge call (defaults to the default provider)

  Returns `{:pass, reasoning}`, `{:fail, reasoning}`, or `{:error, reason}`
  when the LLM call itself fails.
  """
  @spec judge(String.t(), Transcript.t(), keyword()) :: verdict()
  def judge(rubric, %Transcript{} = transcript, opts \\ []) do
    messages = [%UserMessage{content: build_prompt(rubric, transcript)}]

    case SkillKit.LLM.stream(messages, model: Keyword.get(opts, :model)) do
      {:ok, stream} -> verdict(collect_text(stream))
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Verdict parsing
  # ---------------------------------------------------------------------------

  defp verdict(text) do
    cond do
      Regex.match?(~r/VERDICT:\s*PASS/i, text) -> {:pass, String.trim(text)}
      Regex.match?(~r/VERDICT:\s*FAIL/i, text) -> {:fail, String.trim(text)}
      true -> {:fail, "judge returned no verdict; output: #{String.trim(text)}"}
    end
  end

  defp collect_text(stream) do
    stream
    |> Enum.flat_map(&delta_text/1)
    |> Enum.join("")
  end

  defp delta_text(%Delta{text: text}) when is_binary(text), do: [text]
  defp delta_text(_event), do: []

  # ---------------------------------------------------------------------------
  # Prompt construction
  # ---------------------------------------------------------------------------

  defp build_prompt(rubric, transcript) do
    """
    You are an impartial evaluator scoring an AI assistant's behavior against a
    rubric. Judge only against the success criteria below — do not invent extra
    requirements.

    ## Success criteria
    #{rubric}

    ## Tools the assistant called
    #{format_tools(transcript.tool_calls)}

    ## Assistant's final response
    #{format_response(transcript.response)}

    Decide whether the assistant satisfied ALL the success criteria. Reply with
    a single line "VERDICT: PASS" or "VERDICT: FAIL", then a brief justification.
    """
  end

  defp format_tools([]), do: "(none)"
  defp format_tools(tool_calls), do: Enum.map_join(tool_calls, "\n", &"- #{&1}")

  defp format_response(nil), do: "(no response)"
  defp format_response(response), do: response
end
