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
  @spec new(SkillKit.Skill.t(), String.t(), map(), keyword()) :: t()
  def new(skill, command, context, opts \\ []) do
    all_hooks = Keyword.get(opts, :all_hooks, [])
    executor_name = Module.split(skill.executor) |> List.last()

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

    execute_step = {:execute, "execute", skill.executor}

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

    # Find the suspended step and continue from there
    remaining = Enum.drop_while(exec.steps, fn {_type, step_name, _mod} -> step_name != name end)

    case remaining do
      [{:execute, step_name, executor_mod} | rest] ->
        context = build_execute_context(exec)

        case executor_mod.resume(exec.suspended_state, decision, context) do
          {:ok, result} ->
            exec = put_result(exec, step_name, {:ok, result})
            walk_steps(rest, exec)

          {:error, reason} ->
            exec = put_result(exec, step_name, {:error, reason})
            {:error, %{exec | status: :failed}}

          {:pending, state} ->
            {:pending,
             %{exec | status: :suspended, suspended_at: step_name, suspended_state: state}}
        end

      [{:pre_hook, step_name, hook} | rest] ->
        context = build_pre_context(exec)

        case invoke_handler(hook.handler, context) do
          :allow ->
            exec = put_result(exec, step_name, :allow)
            walk_steps(rest, exec)

          {:allow, new_cmd} ->
            exec = exec |> put_result(step_name, {:allow, new_cmd}) |> update_command(new_cmd)
            walk_steps(rest, exec)

          {:deny, reason} ->
            exec = put_result(exec, step_name, {:deny, reason})
            {:error, %{exec | status: :failed}}

          {:pending, state} ->
            {:pending,
             %{exec | status: :suspended, suspended_at: step_name, suspended_state: state}}
        end

      _ ->
        {:error, %{exec | status: :failed}}
    end
  end

  # --- Private helpers ---

  defp walk_steps([], exec) do
    {:ok, %{exec | status: :complete}}
  end

  defp walk_steps([{:pre_hook, name, hook} | rest], exec) do
    context = build_pre_context(exec)

    case invoke_handler(hook.handler, context) do
      :allow ->
        exec = put_result(exec, name, :allow)
        walk_steps(rest, exec)

      {:allow, new_cmd} ->
        exec = exec |> put_result(name, {:allow, new_cmd}) |> update_command(new_cmd)
        walk_steps(rest, exec)

      {:deny, reason} ->
        exec = put_result(exec, name, {:deny, reason})
        {:error, %{exec | status: :failed}}

      {:pending, state} ->
        {:pending, %{exec | status: :suspended, suspended_at: name, suspended_state: state}}
    end
  end

  defp walk_steps([{:execute, name, executor_mod} | rest], exec) do
    context = build_execute_context(exec)

    case executor_mod.execute(exec.command, context) do
      {:ok, result} ->
        exec = put_result(exec, name, {:ok, result})
        walk_steps(rest, exec)

      {:error, reason} ->
        exec = put_result(exec, name, {:error, reason})
        {:error, %{exec | status: :failed}}

      {:pending, state} ->
        {:pending, %{exec | status: :suspended, suspended_at: name, suspended_state: state}}
    end
  end

  defp walk_steps([{:post_hook, name, hook} | rest], exec) do
    execute_result = Map.get(exec.results, "execute")
    context = build_post_context(exec, execute_result)

    case invoke_handler(hook.handler, context) do
      {:ok, result} ->
        exec = put_result(exec, name, {:ok, result})
        walk_steps(rest, exec)

      {:error, reason} ->
        exec = put_result(exec, name, {:error, reason})
        {:error, %{exec | status: :failed}}

      {:pending, state} ->
        {:pending, %{exec | status: :suspended, suspended_at: name, suspended_state: state}}
    end
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

  defp build_pre_context(exec) do
    %{
      skill: exec.skill,
      scope: Map.get(exec.context, :scope),
      command: exec.command,
      executor: exec.skill.executor
    }
  end

  defp build_execute_context(exec) do
    exec.context
  end

  defp build_post_context(exec, result) do
    exec
    |> build_pre_context()
    |> Map.put(:result, result)
  end
end
