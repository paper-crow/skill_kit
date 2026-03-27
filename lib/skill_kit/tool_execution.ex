defmodule SkillKit.ToolExecution do
  @moduledoc """
  Manages tool execution with suspension and resumption.

  A `%ToolExecution{}` holds the tool module, input, context, and
  execution state. It handles the execute/suspend/resume lifecycle
  for tools that need human-in-the-loop approval.

  Hooks are no longer part of this pipeline — they are dispatched
  by `SkillKit.Hooks` at the boundary level in `Agent.Server`.

  ## Status transitions

  - `:pending`   — built but not yet run
  - `:running`   — actively executing
  - `:suspended` — tool returned `{:pending, state}`, awaiting decision
  - `:complete`  — tool succeeded
  - `:failed`    — tool returned an error
  """

  @type status :: :pending | :running | :suspended | :complete | :failed

  @type t :: %__MODULE__{
          skill: SkillKit.Skill.t() | nil,
          tool: module(),
          input: map(),
          context: map(),
          result: any(),
          suspended_state: any(),
          status: status()
        }

  defstruct [
    :skill,
    :tool,
    :input,
    :context,
    :result,
    :suspended_state,
    status: :pending
  ]

  @doc """
  Executes the tool.

  Returns:
  - `{:ok, execution}` — tool completed successfully
  - `{:error, execution}` — tool failed
  - `{:pending, execution}` — tool suspended, awaiting a decision
  """
  @spec execute(t()) :: {:ok, t()} | {:error, t()} | {:pending, t()}
  def execute(%__MODULE__{tool: tool} = exec) do
    exec = %{exec | status: :running}

    case apply(tool, :execute, [exec]) do
      {:ok, value} -> {:ok, %{exec | status: :complete, result: value}}
      {:error, reason} -> {:error, %{exec | status: :failed, result: reason}}
      {:pending, state} -> {:pending, %{exec | status: :suspended, suspended_state: state}}
    end
  end

  @doc """
  Resumes a suspended execution with a decision.

  `decision` is passed directly to the tool's `resume/3` callback.
  """
  @spec resume(t(), any()) :: {:ok, t()} | {:error, t()} | {:pending, t()}
  def resume(%__MODULE__{status: :suspended, tool: tool, suspended_state: state} = exec, decision) do
    exec = %{exec | status: :running}

    case apply(tool, :resume, [exec, state, decision]) do
      {:ok, value} ->
        {:ok, %{exec | status: :complete, result: value}}

      {:error, reason} ->
        {:error, %{exec | status: :failed, result: reason}}

      {:pending, new_state} ->
        {:pending, %{exec | status: :suspended, suspended_state: new_state}}
    end
  end
end
