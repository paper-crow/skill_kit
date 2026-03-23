defmodule SkillKit.Agent.ToolBuilder do
  @moduledoc """
  Assembles the tool list for the LLM from executors, kits, and builtins.

  Skills are NOT tools — they're context loaded via `activate_skill`.
  The tool list consists of:
  - Executor tools (bash) — from executor modules' `tool_definition/0`
  - `activate_skill` — loads a skill's instructions into context
  - Agent delegation tools — from kit agent definitions
  - Built-in tools — report_status/report_result for subagent-agents
  """

  alias SkillKit.Agent.Definition
  alias SkillKit.Executor.ToolDefinition
  alias SkillKit.Kit

  @subagent_builtins MapSet.new(["report_status", "report_result"])

  @doc """
  Builds the full tool list for the LLM.

  Options:
  - `:executors` — list of executor modules (default: `[SkillKit.Executor.Shell]`)
  - `:subagent` — if true, includes report_status/report_result (default: false)
  """
  @spec build_tools([Kit.t()], keyword()) :: [ToolDefinition.t()]
  def build_tools(kits, opts \\ []) do
    executors = Keyword.get(opts, :executors, [SkillKit.Executor.Shell])
    subagent = Keyword.get(opts, :subagent, false)

    all_skills = Enum.flat_map(kits, & &1.skills)
    all_agents = Enum.flat_map(kits, & &1.agents)

    executor_tools = Enum.map(executors, & &1.tool_definition())
    skill_tool = if all_skills != [], do: [activate_skill_tool(all_skills)], else: []
    agent_tools = Enum.map(all_agents, &agent_to_tool/1)
    builtins = if subagent, do: builtin_tools(), else: []

    executor_tools ++ skill_tool ++ agent_tools ++ builtins
  end

  @doc """
  Returns a classifier function for routing tool calls.

  Returns one of: :executor, :activate_skill, :subagent, :builtin
  """
  @spec classifier([Kit.t()]) :: (map() -> :executor | :activate_skill | :subagent | :builtin)
  def classifier(kits) do
    agent_names =
      kits
      |> Enum.flat_map(& &1.agents)
      |> MapSet.new(& &1.name)

    fn %{name: name} ->
      cond do
        name == "activate_skill" -> :activate_skill
        MapSet.member?(@subagent_builtins, name) -> :builtin
        MapSet.member?(agent_names, name) -> :subagent
        true -> :executor
      end
    end
  end

  defp activate_skill_tool(skills) do
    skill_names = Enum.map(skills, & &1.name)
    skill_descriptions = Enum.map_join(skills, "\n", fn s -> "- #{s.name}: #{s.description}" end)

    %ToolDefinition{
      name: "activate_skill",
      description:
        "Load a skill's instructions into your context. Use when you need specialized guidelines " <>
          "for a task (e.g. code review, style conventions). Available skills:\n#{skill_descriptions}",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The skill name to activate",
            "enum" => skill_names
          }
        },
        "required" => ["name"]
      }
    }
  end

  defp agent_to_tool(%Definition{name: name, description: description}) do
    %ToolDefinition{
      name: name,
      description: description,
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "task" => %{
            "type" => "string",
            "description" => "The task to delegate to this agent"
          }
        },
        "required" => ["task"]
      }
    }
  end

  defp builtin_tools do
    [
      %ToolDefinition{
        name: "report_status",
        description:
          "Send a progress update to the parent agent. Use to report intermediate results.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "status" => %{"type" => "string", "description" => "Progress update message"}
          },
          "required" => ["status"]
        }
      },
      %ToolDefinition{
        name: "report_result",
        description:
          "Report the final result and complete this task. The agent stops after this.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "result" => %{"type" => "string", "description" => "Final result of the task"}
          },
          "required" => ["result"]
        }
      }
    ]
  end
end
