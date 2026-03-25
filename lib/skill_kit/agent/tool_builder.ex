defmodule SkillKit.Agent.ToolBuilder do
  @moduledoc """
  Assembles the tool list for the LLM from handlers, kits, and builtins.

  Skills are NOT tools — they're context loaded via `activate_skill`.
  The tool list consists of:
  - Handler tools (bash) — from handler modules' `tool_definition/0`
  - `activate_skill` — loads a skill's instructions into context
  - Agent delegation tools — from kit agent definitions
  - Built-in tools — report_status/report_result for subagent-agents
  """

  alias SkillKit.Agent.Definition
  alias SkillKit.Handler.ToolDefinition
  alias SkillKit.Kit
  alias SkillKit.Skill

  @subagent_builtins MapSet.new(["report_status", "report_result"])

  @doc """
  Builds the full tool list for the LLM.

  Handler tools are discovered from kits that declare a `:handler` in their metadata.

  Options:
  - `:subagent` — if true, includes report_status/report_result (default: false)
  - `:activated_skills` — list of `%Skill{}` structs with module-backed handlers
  """
  @spec build_tools([Kit.t()], keyword()) :: [ToolDefinition.t()]
  def build_tools(kits, opts \\ []) do
    subagent = Keyword.get(opts, :subagent, false)
    activated_skills = Keyword.get(opts, :activated_skills, [])

    all_skills = Enum.flat_map(kits, & &1.skills)
    all_agents = Enum.flat_map(kits, & &1.agents)

    handler_modules = discover_handler_modules(kits)
    handler_tools = Enum.map(handler_modules, & &1.tool_definition())

    activated_tools =
      activated_skills
      |> Enum.filter(&Code.ensure_loaded?(&1.handler))
      |> Enum.map(&skill_to_tool/1)

    handler_set = MapSet.new(handler_modules)

    visible_skills =
      Enum.filter(all_skills, fn skill ->
        MapSet.member?(handler_set, skill.handler) or Code.ensure_loaded?(skill.handler)
      end)

    skill_tool = if visible_skills != [], do: [activate_skill_tool(visible_skills)], else: []
    agent_tools = Enum.map(all_agents, &agent_to_tool/1)
    builtins = if subagent, do: builtin_tools(), else: []

    handler_tools ++ activated_tools ++ skill_tool ++ agent_tools ++ builtins
  end

  @doc """
  Returns a classifier function for routing tool calls.

  Returns one of: :handler, :activate_skill, :subagent, :builtin,
  or `{:module_skill, skill}` for activated module-backed skills.
  """
  @spec classifier([Kit.t()], [Skill.t()]) ::
          (map() ->
             :handler
             | :activate_skill
             | :subagent
             | :builtin
             | {:module_skill, Skill.t()})
  def classifier(kits, activated_skills \\ []) do
    agent_names =
      kits
      |> Enum.flat_map(& &1.agents)
      |> MapSet.new(& &1.name)

    module_skill_map = Map.new(activated_skills, &{skill_short_name(&1.name), &1})

    fn %{name: name} ->
      cond do
        name == "activate_skill" -> :activate_skill
        MapSet.member?(@subagent_builtins, name) -> :builtin
        MapSet.member?(agent_names, name) -> :subagent
        Map.has_key?(module_skill_map, name) -> {:module_skill, module_skill_map[name]}
        true -> :handler
      end
    end
  end

  @doc """
  Extracts the short name from a namespaced skill name.

  ## Examples

      iex> ToolBuilder.skill_short_name("scheduler:schedule")
      "schedule"

      iex> ToolBuilder.skill_short_name("standalone")
      "standalone"
  """
  @spec skill_short_name(String.t()) :: String.t()
  def skill_short_name(name) do
    case String.split(name, ":", parts: 2) do
      [_ns, short] -> short
      [short] -> short
    end
  end

  defp skill_to_tool(skill) do
    %ToolDefinition{
      name: skill_short_name(skill.name),
      description: skill.description,
      input_schema: %{"type" => "object"}
    }
  end

  defp activate_skill_tool(skills) do
    skill_names = Enum.map(skills, & &1.name)
    skill_descriptions = Enum.map_join(skills, "\n", &"- #{&1.name}: #{&1.description}")

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
          },
          "arguments" => %{
            "type" => "string",
            "description" =>
              "Arguments to pass to the skill (space-separated, accessible as $ARGUMENTS, $0, $1, etc.)"
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

  defp discover_handler_modules(kits) do
    kits
    |> Enum.filter(&Map.has_key?(&1.metadata, :handler))
    |> Enum.map(& &1.metadata.handler)
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
