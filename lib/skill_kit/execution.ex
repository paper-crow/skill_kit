defmodule SkillKit.Execution do
  @moduledoc """
  A named, resumable pipeline for executing a skill command through lifecycle hooks.

  Inspired by `Ecto.Multi`, an `Execution` separates construction from execution.
  Each step in the pipeline is a named entry — pre-hooks, the execute step, and
  post-hooks. Steps are walked sequentially; results are recorded in a map keyed
  by step name.

  The pipeline can suspend at any step via `{:pending, state}` and be resumed
  from that exact point with `resume/2`.

  ## Status transitions

  - `:pending`   — initial state after `new/4`
  - `:running`   — actively processing steps
  - `:suspended` — paused at a step awaiting a decision
  - `:complete`  — all steps succeeded
  - `:failed`    — a step returned an error or denial

  ## Step naming

  - Pre-hooks: `"pre:0"`, `"pre:1"`, ...
  - Execute:   `"execute"`
  - Post-hooks: `"post:0"`, `"post:1"`, ...
  """

  alias SkillKit.Hook

  @type step ::
          {:pre_hook, String.t(), Hook.t()}
          | {:execute, String.t(), module()}
          | {:post_hook, String.t(), Hook.t()}

  @type status :: :pending | :running | :suspended | :complete | :failed

  @type t :: %__MODULE__{
          skill: SkillKit.Skill.t(),
          command: String.t(),
          context: map(),
          steps: [step()],
          results: map(),
          status: status(),
          suspended_at: String.t() | nil,
          suspended_state: any()
        }

  defstruct [
    :skill,
    :command,
    :context,
    :suspended_at,
    :suspended_state,
    steps: [],
    results: %{},
    status: :pending
  ]

  @doc """
  Builds an `Execution` pipeline for `skill`, `command`, and `context`.

  Hooks are passed via the `all_hooks:` option. Only hooks whose `:matcher`
  regex matches the last segment of the executor module name are included.

  ## Options

  - `all_hooks:` — list of `SkillKit.Hook.t()` to filter and insert into the pipeline
  """
  @spec new(SkillKit.Skill.t() | nil, String.t(), map(), keyword()) :: t()
  def new(skill, command, context, opts \\ []) do
    all_hooks = Keyword.get(opts, :all_hooks, [])
    executor = resolve_executor(skill, opts)
    executor_name = executor_name(executor)

    matching_hooks =
      Enum.filter(all_hooks, fn %Hook{matcher: matcher} ->
        Regex.match?(matcher, executor_name)
      end)

    pre_hooks = Enum.filter(matching_hooks, &(&1.phase == :pre))
    post_hooks = Enum.filter(matching_hooks, &(&1.phase == :post))

    pre_steps =
      pre_hooks
      |> Enum.with_index()
      |> Enum.map(fn {hook, i} -> {:pre_hook, "pre:#{i}", hook} end)

    execute_step = {:execute, "execute", executor}

    post_steps =
      post_hooks
      |> Enum.with_index()
      |> Enum.map(fn {hook, i} -> {:post_hook, "post:#{i}", hook} end)

    steps = pre_steps ++ [execute_step] ++ post_steps

    %__MODULE__{
      skill: skill,
      command: command,
      context: context,
      steps: steps,
      results: %{},
      status: :pending,
      suspended_at: nil,
      suspended_state: nil
    }
  end

  @doc """
  Walks all pipeline steps sequentially, recording results by step name.

  Returns:
  - `{:ok, execution}` — all steps completed successfully
  - `{:error, execution}` — a step failed or was denied
  - `{:pending, execution}` — a step suspended, waiting for a decision
  """
  @spec run(t()) :: {:ok, t()} | {:error, t()} | {:pending, t()}
  def run(%__MODULE__{} = exec) do
    exec = %{exec | status: :running}
    walk_steps(exec.steps, exec)
  end

  @doc """
  Resumes a suspended `Execution` from the step it was suspended at.

  `decision` is passed directly to the suspended executor's `resume/3` callback,
  or used to re-invoke a suspended hook.
  """
  @spec resume(t(), any()) :: {:ok, t()} | {:error, t()} | {:pending, t()}
  def resume(%__MODULE__{status: :suspended, suspended_at: name} = exec, decision) do
    exec = %{exec | status: :running}
    remaining = Enum.drop_while(exec.steps, fn {_type, step_name, _mod} -> step_name != name end)

    case remaining do
      [{:execute, _step_name, executor_mod} | _rest] ->
        result = executor_mod.resume(exec, exec.suspended_state, decision)
        apply_step_result(remaining, exec, result)

      [{_hook_type, _step_name, hook} | _rest] ->
        context = build_pre_context(exec)
        result = invoke_handler(hook.handler, context)
        apply_step_result(remaining, exec, result)

      _ ->
        {:error, %{exec | status: :failed}}
    end
  end

  # Applies a step result and continues walking. Used by both walk_steps and resume
  # to avoid duplicating the result-handling logic.
  defp apply_step_result([{type, name, _handler} | rest], exec, result) do
    case {type, result} do
      {_, {:pending, state}} ->
        {:pending, %{exec | status: :suspended, suspended_at: name, suspended_state: state}}

      {:pre_hook, :allow} ->
        walk_steps(rest, put_result(exec, name, :allow))

      {:pre_hook, {:allow, new_cmd}} ->
        exec = exec |> put_result(name, {:allow, new_cmd}) |> update_command(new_cmd)
        walk_steps(rest, exec)

      {:pre_hook, {:deny, reason}} ->
        {:error, %{put_result(exec, name, {:deny, reason}) | status: :failed}}

      {_, {:ok, value}} ->
        walk_steps(rest, put_result(exec, name, {:ok, value}))

      {_, {:error, reason}} ->
        {:error, %{put_result(exec, name, {:error, reason}) | status: :failed}}
    end
  end

  # --- Private helpers ---

  defp walk_steps([], exec) do
    {:ok, %{exec | status: :complete}}
  end

  defp walk_steps([{:pre_hook, _name, hook} | _rest] = steps, exec) do
    context = build_pre_context(exec)
    apply_step_result(steps, exec, invoke_handler(hook.handler, context))
  end

  defp walk_steps([{:execute, _name, executor_mod} | _rest] = steps, exec) do
    apply_step_result(steps, exec, executor_mod.execute(exec))
  end

  defp walk_steps([{:post_hook, _name, hook} | _rest] = steps, exec) do
    execute_result = Map.get(exec.results, "execute")
    context = build_post_context(exec, execute_result)
    apply_step_result(steps, exec, invoke_handler(hook.handler, context))
  end

  defp invoke_handler(fun, context) when is_function(fun, 1) do
    fun.(context)
  end

  defp invoke_handler({mod, fun, args}, context) do
    apply(mod, fun, [context | args])
  end

  defp put_result(exec, name, value) do
    %{exec | results: Map.put(exec.results, name, value)}
  end

  defp update_command(exec, new_cmd) do
    %{exec | command: new_cmd}
  end

  defp executor_name(executor) do
    executor
    |> Module.split()
    |> List.last()
  end

  defp resolve_executor(nil, opts), do: Keyword.fetch!(opts, :executor)
  defp resolve_executor(skill, _opts), do: skill.executor

  defp build_pre_context(%{skill: nil, steps: steps} = exec) do
    {:execute, _, executor} = Enum.find(steps, &match?({:execute, _, _}, &1))

    %{
      skill: nil,
      scope: Map.get(exec.context, :scope),
      command: exec.command,
      executor: executor
    }
  end

  defp build_pre_context(exec) do
    %{
      skill: exec.skill,
      scope: Map.get(exec.context, :scope),
      command: exec.command,
      executor: exec.skill.executor
    }
  end

  defp build_post_context(exec, result) do
    exec
    |> build_pre_context()
    |> Map.put(:result, result)
  end
end
