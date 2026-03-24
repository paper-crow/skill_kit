defmodule SkillKit.Handler do
  @moduledoc """
  Builds and runs `%Pipeline{}` pipelines.

  Public entry point for executing skill input through the pipeline.
  Accepts input as a map (e.g., `%{"command" => "echo hi"}`) or a
  bare command string (wrapped automatically). Collects hooks from
  all registered skills, builds the execution pipeline, and runs it.

  For callers that need pipeline inspection or suspension support,
  use `SkillKit.Pipeline` directly.
  """

  alias SkillKit.Pipeline
  alias SkillKit.Registry

  @doc """
  Runs input through the execution pipeline without a specific skill.

  Accepts a map or bare command string. Uses the configured handler
  from `config :skill_kit, :handler` (defaults to `SkillKit.Handler.Shell`).
  """
  def run(registry, input, context) do
    handler = Application.get_env(:skill_kit, :handler, SkillKit.Handler.Shell)
    hooks = collect_and_filter_hooks(registry, handler)
    input = wrap_input(input)
    pipeline = Pipeline.new(nil, input, context, hooks: hooks, handler: handler)
    Pipeline.run(pipeline)
  end

  @doc """
  Runs a skill's input through the execution pipeline.

  Accepts a map or bare command string. Collects hooks from all
  registered skills, builds the pipeline, and runs it.
  """
  def run(registry, skill, input, context) do
    hooks = collect_and_filter_hooks(registry, skill.handler)
    input = wrap_input(input)
    pipeline = Pipeline.new(skill, input, context, hooks: hooks)
    Pipeline.run(pipeline)
  end

  @doc """
  Resumes a suspended execution with an approval decision.
  """
  def resume(execution, decision) do
    Pipeline.resume(execution, decision)
  end

  defp wrap_input(input) when is_map(input), do: input
  defp wrap_input(command) when is_binary(command), do: %{"command" => command}

  defp collect_and_filter_hooks(registry, handler) do
    handler_name = handler |> Module.split() |> List.last()

    registry
    |> Registry.list_skills()
    |> Enum.flat_map(& &1.hooks)
    |> Enum.filter(&Regex.match?(&1.matcher, handler_name))
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
