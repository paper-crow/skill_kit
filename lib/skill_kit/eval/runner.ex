defmodule SkillKit.Eval.Runner do
  @moduledoc """
  Runs a single eval and scores it.

  The runner spins up a throwaway agent loaded with the eval's `skills` and
  `tools`, sends the eval's prompt, and collects the resulting transcript
  (final response + tool calls). A run is scored by two kinds of check: a
  deterministic **completion** check (did the agent respond at all, vs.
  erroring or timing out) and the **LLM judge** scoring the transcript against
  the eval's `## Expect` rubric.

  The agent and judge both run through `SkillKit.LLM`, so the configured
  provider decides behavior: a real provider for `mix test --include eval`,
  the mock for the harness's own unit tests.
  """

  alias SkillKit.Agent
  alias SkillKit.Eval
  alias SkillKit.Eval.Cache
  alias SkillKit.Eval.Check
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
    * `:judge` — set `false` to skip the LLM-judge check (default `true`)
    * `:model` — overrides the eval's agent model
    * `:judge_model` — model URI for the judge (defaults to the eval's model)
    * `:cache` — skip cases whose scope already passed. `true` uses the default
      cache under `_build`, a string uses that path, `false` (default) disables
      caching. See `SkillKit.Eval.Cache`.
  """
  @spec run(Eval.t(), keyword()) :: Result.t()
  def run(%Eval{} = eval, opts \\ []) do
    run_cached(Keyword.get(opts, :cache, false), eval, opts)
  end

  defp run_cached(false, eval, opts), do: score(eval, opts)

  defp run_cached(cache, eval, opts) do
    path = cache_path(cache)
    fingerprint = Cache.fingerprint(eval, opts)

    case Cache.get(path, fingerprint) do
      :pass -> cached_result(eval)
      :miss -> score_and_record(eval, opts, path, fingerprint)
    end
  end

  defp cache_path(true), do: Cache.default_path()
  defp cache_path(path) when is_binary(path), do: path

  defp score_and_record(eval, opts, path, fingerprint) do
    result = score(eval, opts)
    record_if_passed(Result.passed?(result), path, fingerprint, eval.name)
    result
  end

  defp record_if_passed(true, path, fingerprint, name), do: Cache.put(path, fingerprint, name)
  defp record_if_passed(false, _path, _fingerprint, _name), do: :ok

  defp cached_result(eval) do
    %Result{eval: eval, transcript: %Transcript{status: :ok}, checks: [], cached: true}
  end

  defp score(eval, opts) do
    transcript = run_agent(eval, opts)
    checks = completion_checks(transcript) ++ judge_checks(eval, transcript, opts)
    %Result{eval: eval, transcript: transcript, checks: checks}
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
    [tools: eval.tools, skills: Eval.skill_providers(eval), caller: self()]
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
  # Scoring
  # ---------------------------------------------------------------------------

  defp completion_checks(%Transcript{status: :ok}), do: []

  defp completion_checks(%Transcript{status: :error, error: reason}) do
    [Check.fail("agent completed", "agent errored: #{inspect(reason)}")]
  end

  defp completion_checks(%Transcript{status: :timeout}) do
    [Check.fail("agent completed", "agent timed out before responding")]
  end

  defp completion_checks(%Transcript{status: :pending}) do
    [Check.fail("agent completed", "agent produced no response")]
  end

  # No judging without a rubric, or when the run didn't complete cleanly.
  defp judge_checks(%Eval{rubric: nil}, _transcript, _opts), do: []
  defp judge_checks(_eval, %Transcript{status: status}, _opts) when status != :ok, do: []

  defp judge_checks(eval, transcript, opts) do
    if Keyword.get(opts, :judge, true) do
      [judge_check(eval, transcript, opts)]
    else
      []
    end
  end

  defp judge_check(eval, transcript, opts) do
    judge_opts = [model: Keyword.get(opts, :judge_model, eval.model), prompt: eval.prompt]

    eval.rubric
    |> Judge.judge(transcript, judge_opts)
    |> verdict_check()
  end

  defp verdict_check({:pass, reasoning}), do: Check.pass("llm-judge: rubric satisfied", reasoning)
  defp verdict_check({:fail, reasoning}), do: Check.fail("llm-judge: rubric satisfied", reasoning)

  defp verdict_check({:error, reason}) do
    Check.fail("llm-judge: rubric satisfied", "judge call failed: #{inspect(reason)}")
  end
end
