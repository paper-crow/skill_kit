defmodule SkillKit.ToolExecution do
  @moduledoc """
  The execution pipeline for tool calls.

  A `%ToolExecution{}` is a named, resumable pipeline that runs skill input
  through lifecycle hooks. It holds a list of steps (pre-hooks, an execute
  step, and post-hooks), input, context, and accumulated results.

  ## Entry points

  - `start/3,4` — build and run a pipeline (was `Tool.Runner.run`)
  - `resume/2` — resume a suspended pipeline

  ## Status transitions

  - `:pending`   — initial state
  - `:running`   — actively processing steps
  - `:suspended` — paused at a step awaiting a decision
  - `:complete`  — all steps succeeded
  - `:failed`    — a step returned an error or denial

  ## Step naming

  Steps are named during construction:

  - Pre-hooks: `"pre:0"`, `"pre:1"`, ...
  - Execute:   `"execute"`
  - Post-hooks: `"post:0"`, `"post:1"`, ...
  """

  alias SkillKit.Hook
  alias SkillKit.Skill

  @type step ::
          {:pre_hook, String.t(), Hook.t()}
          | {:execute, String.t(), module()}
          | {:post_hook, String.t(), Hook.t()}

  @type status :: :pending | :running | :suspended | :complete | :failed

  @type t :: %__MODULE__{
          skill: Skill.t() | nil,
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

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Builds and runs an execution pipeline.

  Two forms:

    * `start(catalog, %Skill{}, input, context)` — uses the tool from the skill struct.
    * `start(tool_module, catalog, input, context)` — explicit tool module
      (must be an atom). Used by the agent server for bare commands.

  The catalog (or any process implementing hooks retrieval) is used to
  collect lifecycle hooks for the pipeline.
  """
  def start(catalog, skill_or_input, input, context \\ %{})

  def start(catalog, %Skill{} = skill, input, context) do
    hooks = collect_and_filter_hooks(catalog, skill.tool)

    %__MODULE__{
      skill: skill,
      input: wrap_input(input),
      context: context,
      steps: build_steps(hooks, skill.tool)
    }
    |> execute()
  end

  def start(tool, catalog, input, context) when is_atom(tool) do
    hooks = collect_and_filter_hooks(catalog, tool)

    %__MODULE__{
      skill: nil,
      input: wrap_input(input),
      context: context,
      steps: build_steps(hooks, tool)
    }
    |> execute()
  end

  @doc """
  Resumes a suspended execution with an approval decision.

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

  # -------------------------------------------------------------------
  # Internal execution
  # -------------------------------------------------------------------

  @doc """
  Walks all pipeline steps sequentially, recording results by step name.

  Returns:
  - `{:ok, execution}` — all steps completed successfully
  - `{:error, execution}` — a step failed or was denied
  - `{:pending, execution}` — a step suspended, waiting for a decision
  """
  @spec execute(t()) :: {:ok, t()} | {:error, t()} | {:pending, t()}
  def execute(%__MODULE__{} = exec) do
    exec = %{exec | status: :running}
    walk_steps(exec.steps, exec)
  end

  # -------------------------------------------------------------------
  # Private helpers — step walking
  # -------------------------------------------------------------------

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

  # -------------------------------------------------------------------
  # Private helpers — hook collection and step building
  # -------------------------------------------------------------------

  defp collect_and_filter_hooks(catalog, tool) do
    tool_name = tool |> Module.split() |> List.last()
    pre = SkillKit.Catalog.list_hooks(catalog, :pre_tool_use)
    post = SkillKit.Catalog.list_hooks(catalog, :post_tool_use)
    all_hooks = pre ++ post
    Enum.filter(all_hooks, &Regex.match?(&1.matcher, tool_name))
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp build_steps(hooks, tool) do
    pre_steps =
      hooks |> Enum.filter(&(&1.event == :pre_tool_use)) |> index_steps(:pre_hook, "pre")

    post_steps =
      hooks |> Enum.filter(&(&1.event == :post_tool_use)) |> index_steps(:post_hook, "post")

    pre_steps ++ [{:execute, "execute", tool}] ++ post_steps
  end

  defp index_steps(hooks, type, prefix) do
    Enum.with_index(hooks, fn %Hook{} = hook, i -> {type, "#{prefix}:#{i}", hook} end)
  end

  # -------------------------------------------------------------------
  # Private helpers — input and context
  # -------------------------------------------------------------------

  defp wrap_input(input) when is_map(input), do: input
  defp wrap_input(command) when is_binary(command), do: %{"command" => command}

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
    {:execute, _, tool} = Enum.find(steps, &match?({:execute, _, _}, &1))

    %{
      skill: nil,
      scope: Map.get(exec.context, :scope),
      input: exec.input,
      tool: tool
    }
  end

  defp build_pre_context(exec) do
    %{
      skill: exec.skill,
      scope: Map.get(exec.context, :scope),
      input: exec.input,
      tool: exec.skill.tool
    }
  end

  defp build_post_context(exec, result) do
    exec
    |> build_pre_context()
    |> Map.put(:result, result)
  end
end
