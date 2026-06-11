defmodule SkillKit.Eval.Runner do
  @moduledoc """
  Runs a single eval and scores it.

  The runner spins up a throwaway agent loaded with the eval's `skills` and
  `tools`, sends the eval's `prompt`, and collects the resulting transcript
  (final response + tool calls). It then scores the transcript with
  `SkillKit.Eval.Expectation` (deterministic) and, when the eval has a rubric,
  `SkillKit.Eval.Judge` (LLM-as-judge), returning a `SkillKit.Eval.Result`.

  The agent and judge both run through `SkillKit.LLM`, so the configured
  provider decides behavior: a real provider for `mix test --include eval`,
  the mock for the harness's own unit tests.
  """

  alias SkillKit.Agent
  alias SkillKit.Eval
  alias SkillKit.Eval.Check
  alias SkillKit.Eval.Expectation
  alias SkillKit.Eval.Judge
  alias SkillKit.Eval.Result
  alias SkillKit.Eval.Transcript
  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Event.ToolCallComplete
  alias SkillKit.Types.AssistantMessage

  @default_timeout 30_000

  @default_system "You are a helpful assistant being evaluated. Use the skills " <>
                    "and tools available to you to satisfy the user's request."

  @doc """
  Runs `eval` and returns a `SkillKit.Eval.Result`.

  Options:
    * `:timeout` — ms to wait for the agent to respond (default `#{@default_timeout}`)
    * `:judge` — set `false` to skip the LLM-judge check even when a rubric
      is present (default `true`)
    * `:model` — overrides the eval's agent model
    * `:judge_model` — model URI for the judge (defaults to the eval's model)
  """
  @spec run(Eval.t(), keyword()) :: Result.t()
  def run(%Eval{} = eval, opts \\ []) do
    transcript = run_agent(eval, opts)
    deterministic = Expectation.evaluate(eval, transcript)
    judged = judge_checks(eval, transcript, opts)
    %Result{eval: eval, transcript: transcript, checks: deterministic ++ judged}
  end

  # ---------------------------------------------------------------------------
  # Agent run
  # ---------------------------------------------------------------------------

  defp run_agent(eval, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    {:ok, agent} = SkillKit.start_agent(agent_definition(eval, opts), start_opts(eval))

    try do
      :ok = SkillKit.send_message(agent, eval.prompt)
      collect(agent.name, timeout, %Transcript{})
    after
      SkillKit.stop_agent(agent)
    end
  end

  defp start_opts(eval) do
    [tools: eval.tools, skills: eval.skills, caller: self()]
  end

  defp agent_definition(eval, opts) do
    %Agent{
      name: "eval-#{:erlang.unique_integer([:positive])}",
      description: "SkillKit eval harness agent",
      system_prompt: eval.system || @default_system,
      model: Keyword.get(opts, :model, eval.model),
      max_agent_depth: 2
    }
  end

  defp collect(name, timeout, acc) do
    receive do
      %ToolCallComplete{agent: ^name, name: tool} ->
        collect(name, timeout, %{acc | tool_calls: [tool | acc.tool_calls]})

      %AssistantMessage{agent: ^name, content: content} ->
        finalize(acc, %{response: content, status: :ok})

      %EventError{agent: ^name, reason: reason} ->
        finalize(acc, %{error: reason, status: :error})

      _other ->
        collect(name, timeout, acc)
    after
      timeout -> finalize(acc, %{status: :timeout})
    end
  end

  defp finalize(acc, fields) do
    acc
    |> Map.merge(fields)
    |> Map.update!(:tool_calls, &Enum.reverse/1)
  end

  # ---------------------------------------------------------------------------
  # Judging
  # ---------------------------------------------------------------------------

  defp judge_checks(%Eval{rubric: nil}, _transcript, _opts), do: []

  defp judge_checks(eval, transcript, opts) do
    if Keyword.get(opts, :judge, true) do
      [judge_check(eval, transcript, opts)]
    else
      []
    end
  end

  defp judge_check(eval, transcript, opts) do
    judge_model = Keyword.get(opts, :judge_model, eval.model)

    eval.rubric
    |> Judge.judge(transcript, model: judge_model)
    |> verdict_check()
  end

  defp verdict_check({:pass, reasoning}), do: Check.pass("llm-judge: rubric satisfied", reasoning)
  defp verdict_check({:fail, reasoning}), do: Check.fail("llm-judge: rubric satisfied", reasoning)

  defp verdict_check({:error, reason}) do
    Check.fail("llm-judge: rubric satisfied", "judge call failed: #{inspect(reason)}")
  end
end
