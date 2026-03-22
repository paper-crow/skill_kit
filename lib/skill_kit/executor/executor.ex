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
  Convenience function that builds and runs an execution pipeline.

  Collects hooks from all registered skills, builds the pipeline,
  and runs it in one call.
  """
  def run(registry, skill, command, context) do
    all_hooks = collect_hooks(registry)
    execution = Execution.new(skill, command, context, all_hooks: all_hooks)
    Execution.run(execution)
  end

  @doc """
  Resumes a suspended execution with an approval decision.
  """
  def resume(execution, decision) do
    Execution.resume(execution, decision)
  end

  defp collect_hooks(registry) do
    registry
    |> Registry.list_skills()
    |> Enum.flat_map(fn skill -> skill.hooks end)
  end
end
