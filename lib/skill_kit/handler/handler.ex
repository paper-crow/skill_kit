defmodule SkillKit.Handler do
  @moduledoc """
  Builds and runs `%Pipeline{}` pipelines.

  Public entry point for executing skill input through the pipeline.
  Accepts input as a map (e.g., `%{"command" => "echo hi"}`) or a
  bare command string (wrapped automatically). Collects hooks from
  all registered skills, filters them by handler, builds the step
  list, and runs the pipeline.

  For callers that need pipeline inspection or suspension support,
  use `SkillKit.Pipeline` directly.
  """

  alias SkillKit.Hook
  alias SkillKit.Pipeline
  alias SkillKit.Skill

  @doc """
  Runs input through the execution pipeline.

  Two forms:

    * `run(catalog, %Skill{}, input, context)` — uses the handler from the skill struct.
    * `run(handler_module, catalog, input, context)` — explicit handler module
      (must be an atom). Used by the agent server for bare commands.

  The catalog (or any process implementing hooks retrieval) is used to
  collect lifecycle hooks for the pipeline.
  """
  def run(catalog, %Skill{} = skill, input, context) do
    hooks = collect_and_filter_hooks(catalog, skill.tool)

    %Pipeline{
      skill: skill,
      input: wrap_input(input),
      context: context,
      steps: build_steps(hooks, skill.tool)
    }
    |> Pipeline.run()
  end

  def run(handler, catalog, input, context) when is_atom(handler) do
    hooks = collect_and_filter_hooks(catalog, handler)

    %Pipeline{
      skill: nil,
      input: wrap_input(input),
      context: context,
      steps: build_steps(hooks, handler)
    }
    |> Pipeline.run()
  end

  @doc """
  Resumes a suspended execution with an approval decision.
  """
  def resume(execution, decision) do
    Pipeline.resume(execution, decision)
  end

  defp wrap_input(input) when is_map(input), do: input
  defp wrap_input(command) when is_binary(command), do: %{"command" => command}

  defp collect_and_filter_hooks(catalog, handler) do
    handler_name = handler |> Module.split() |> List.last()

    catalog
    |> SkillKit.Catalog.hooks()
    |> Enum.filter(&Regex.match?(&1.matcher, handler_name))
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp build_steps(hooks, handler) do
    pre_steps = hooks |> Enum.filter(&(&1.phase == :pre)) |> index_steps(:pre_hook, "pre")
    post_steps = hooks |> Enum.filter(&(&1.phase == :post)) |> index_steps(:post_hook, "post")

    pre_steps ++ [{:execute, "execute", handler}] ++ post_steps
  end

  defp index_steps(hooks, type, prefix) do
    Enum.with_index(hooks, fn %Hook{} = hook, i -> {type, "#{prefix}:#{i}", hook} end)
  end
end
