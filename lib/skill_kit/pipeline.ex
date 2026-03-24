defmodule SkillKit.Pipeline do
  @moduledoc """
  A named, resumable pipeline for executing skill input through lifecycle hooks.

  A pipeline is a data structure holding a list of steps (pre-hooks, an execute
  step, and post-hooks), input, context, and accumulated results. It is built
  by `SkillKit.Handler` and executed by `run/1`.

  Steps are walked sequentially; results are recorded in a map keyed by step
  name. The pipeline can suspend at any step via `{:pending, state}` and be
  resumed from that exact point with `resume/2`.

  ## Status transitions

  - `:pending`   — initial state
  - `:running`   — actively processing steps
  - `:suspended` — paused at a step awaiting a decision
  - `:complete`  — all steps succeeded
  - `:failed`    — a step returned an error or denial

  ## Step naming

  Steps are named by `SkillKit.Handler` during construction:

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
          input: map(),
          context: map(),
          steps: [step()],
          results: map(),
          status: status(),
          suspended_at: String.t() | nil,
          suspended_state: any()
        }

  defstruct [
    :skill,
    :input,
    :context,
    :suspended_at,
    :suspended_state,
    steps: [],
    results: %{},
    status: :pending
  ]

  @doc """
  Walks all pipeline steps sequentially, recording results by step name.

  Returns:
  - `{:ok, pipeline}` — all steps completed successfully
  - `{:error, pipeline}` — a step failed or was denied
  - `{:pending, pipeline}` — a step suspended, waiting for a decision
  """
  @spec run(t()) :: {:ok, t()} | {:error, t()} | {:pending, t()}
  def run(%__MODULE__{} = exec) do
    exec = %{exec | status: :running}
    walk_steps(exec.steps, exec)
  end

  @doc """
  Resumes a suspended `Pipeline` from the step it was suspended at.

  `decision` is passed directly to the suspended handler's `resume/3` callback,
  or used to re-invoke a suspended hook.
  """
  @spec resume(t(), any()) :: {:ok, t()} | {:error, t()} | {:pending, t()}
  def resume(%__MODULE__{status: :suspended, suspended_at: name} = exec, decision) do
    exec = %{exec | status: :running}
    remaining = Enum.drop_while(exec.steps, fn {_type, step_name, _mod} -> step_name != name end)

    case remaining do
      [{:execute, _step_name, handler_mod} | _rest] ->
        result = handler_mod.resume(exec, exec.suspended_state, decision)
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
        exec = exec |> put_result(name, {:allow, new_cmd}) |> update_input(new_cmd)
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

  defp walk_steps([{:execute, _name, handler_mod} | _rest] = steps, exec) do
    apply_step_result(steps, exec, handler_mod.execute(exec))
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

  defp update_input(exec, new_input) do
    %{exec | input: new_input}
  end

  defp build_pre_context(%{skill: nil, steps: steps} = exec) do
    {:execute, _, handler} = Enum.find(steps, &match?({:execute, _, _}, &1))

    %{
      skill: nil,
      scope: Map.get(exec.context, :scope),
      input: exec.input,
      handler: handler
    }
  end

  defp build_pre_context(exec) do
    %{
      skill: exec.skill,
      scope: Map.get(exec.context, :scope),
      input: exec.input,
      handler: exec.skill.handler
    }
  end

  defp build_post_context(exec, result) do
    exec
    |> build_pre_context()
    |> Map.put(:result, result)
  end
end
