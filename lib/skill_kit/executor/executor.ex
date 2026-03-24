defmodule SkillKit.Executor do
  @moduledoc """
  Builds and runs `%Execution{}` pipelines.

  This is the public entry point for executing a skill's command.
  It collects hooks from all registered skills in the registry,
  builds the execution pipeline, and runs it.

  For callers that need pipeline inspection or suspension support,
  use `SkillKit.Execution` directly.
  """

  alias SkillKit.Execution
  alias SkillKit.Registry

  @doc """
  Runs a command through the execution pipeline without a specific skill.

  Uses the configured executor from `config :skill_kit, :executor`
  (defaults to `SkillKit.Executor.Shell`). Hooks from all registered
  skills are collected and fired.
  """
  def run(registry, command, context) do
    executor = Application.get_env(:skill_kit, :executor, SkillKit.Executor.Shell)
    all_hooks = collect_hooks(registry)
    input = wrap_input(command)
    execution = Execution.new(nil, input, context, all_hooks: all_hooks, executor: executor)
    Execution.run(execution)
  end

  @doc """
  Runs a skill's command through the execution pipeline.

  Collects hooks from all registered skills, builds the pipeline,
  and runs it in one call.
  """
  def run(registry, skill, command, context) do
    all_hooks = collect_hooks(registry)
    input = wrap_input(command)
    execution = Execution.new(skill, input, context, all_hooks: all_hooks)
    Execution.run(execution)
  end

  @doc """
  Resumes a suspended execution with an approval decision.
  """
  def resume(execution, decision) do
    Execution.resume(execution, decision)
  end

  defp wrap_input(%{} = input), do: input
  defp wrap_input(command) when is_binary(command), do: %{"command" => command}

  defp collect_hooks(registry) do
    registry
    |> Registry.list_skills()
    |> Enum.flat_map(& &1.hooks)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
