defmodule SkillKit.Eval.Result do
  @moduledoc """
  The outcome of running one eval: the eval, the captured transcript, and the
  list of `%SkillKit.Eval.Check{}` scored against it.

  An eval passes only when every check passes. `failure_message/1` renders the
  failing checks and transcript into the message ExUnit shows when a generated
  eval test fails.
  """

  alias SkillKit.Eval
  alias SkillKit.Eval.Check
  alias SkillKit.Eval.Cost
  alias SkillKit.Eval.Transcript

  @type t :: %__MODULE__{
          eval: Eval.t(),
          transcript: Transcript.t(),
          checks: [Check.t()],
          usage: Transcript.usage(),
          cost: float() | nil,
          cached: boolean()
        }

  @empty_usage %{
    input_tokens: 0,
    output_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0
  }

  @enforce_keys [:eval, :transcript, :checks]
  defstruct [:eval, :transcript, :checks, usage: @empty_usage, cost: nil, cached: false]

  @doc "True when every check passed."
  @spec passed?(t()) :: boolean()
  def passed?(%__MODULE__{checks: checks}), do: Enum.all?(checks, & &1.passed)

  @doc "The checks that failed."
  @spec failures(t()) :: [Check.t()]
  def failures(%__MODULE__{checks: checks}), do: Enum.reject(checks, & &1.passed)

  @doc "Non-fatal warning notes from checks that passed (e.g. the judge's)."
  @spec warnings(t()) :: [String.t()]
  def warnings(%__MODULE__{checks: checks}) do
    checks
    |> Enum.filter(& &1.warning)
    |> Enum.map(& &1.warning)
  end

  @doc """
  A human-readable explanation of why the eval failed, for ExUnit output.

  Renders the failing checks (including the judge's verdict and reasoning) plus
  the captured transcript — the prompt sent, the tools the agent called, and its
  response — so a failure shows both *what* was judged and *why*.
  """
  @spec failure_message(t()) :: String.t()
  def failure_message(%__MODULE__{} = result) do
    """
    eval #{inspect(result.eval.name)} failed #{count(result)}:

    #{format_failures(failures(result))}

    #{format_transcript(result)}
    """
  end

  defp count(result) do
    failed = length(failures(result))
    total = length(result.checks)
    "#{failed}/#{total} checks"
  end

  defp format_failures(failures) do
    Enum.map_join(failures, "\n\n", &format_failure/1)
  end

  defp format_failure(%Check{name: name, detail: nil}), do: "  ✗ #{name}"
  defp format_failure(%Check{name: name, detail: detail}), do: "  ✗ #{name}\n#{indent(detail)}"

  defp format_transcript(%__MODULE__{eval: eval, transcript: transcript, cost: cost}) do
    lines = [
      "── transcript ──",
      "  cost: #{Cost.format(cost)}",
      labeled("prompt", eval.prompt),
      "  tools called: #{format_tools(transcript.tool_calls)}",
      transcript_body(transcript)
    ]

    Enum.join(lines, "\n")
  end

  defp transcript_body(%Transcript{status: :ok, response: response}) do
    labeled("response", response)
  end

  defp transcript_body(%Transcript{status: :error, error: error}) do
    "  error: #{inspect(error)}"
  end

  defp transcript_body(%Transcript{status: status}), do: "  status: #{status}"

  defp labeled(label, nil), do: "  #{label}: (none)"
  defp labeled(label, text), do: "  #{label}:\n#{indent(text)}"

  defp format_tools([]), do: "(none)"
  defp format_tools(names), do: Enum.join(names, ", ")

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &("      " <> &1))
  end
end
