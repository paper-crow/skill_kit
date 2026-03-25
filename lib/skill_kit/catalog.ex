defmodule SkillKit.Catalog do
  @moduledoc """
  Aggregates kits from multiple providers and exposes skills, agents, hooks,
  tool definitions, and tool call classification.

  ## Always Fresh

  Every query calls providers via `list_kits/1` — there is no internal
  caching. This ensures the catalog always reflects the current state of
  providers (important for Kit.Memory and other dynamic sources).
  """

  use GenServer

  require Logger

  alias SkillKit.Agent.Definition
  alias SkillKit.Authorization
  alias SkillKit.Handler.ToolDefinition
  alias SkillKit.Skill

  @subagent_builtins MapSet.new(["report_status", "report_result"])

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc "Starts the catalog GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    providers = Keyword.fetch!(opts, :providers)
    scope = Keyword.get(opts, :scope)
    name = Keyword.get(opts, :name)

    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, {providers, scope}, gen_opts)
  end

  @spec list_skills(GenServer.server()) :: [{String.t(), String.t()}]
  def list_skills(catalog) do
    GenServer.call(catalog, :list_skills)
  end

  @spec get_skill(GenServer.server(), String.t()) ::
          {:ok, Skill.t()} | {:error, :not_found | :unauthorized}
  def get_skill(catalog, name) do
    GenServer.call(catalog, {:get_skill, name})
  end

  @spec list_agents(GenServer.server()) :: [Definition.t()]
  def list_agents(catalog) do
    GenServer.call(catalog, :list_agents)
  end

  @spec get_agent(GenServer.server(), String.t()) ::
          {:ok, Definition.t()} | {:error, :not_found}
  def get_agent(catalog, name) do
    GenServer.call(catalog, {:get_agent, name})
  end

  @spec root_agent(GenServer.server()) :: Definition.t() | nil
  def root_agent(catalog) do
    GenServer.call(catalog, :root_agent)
  end

  @spec hooks(GenServer.server()) :: [SkillKit.Hook.t()]
  def hooks(catalog) do
    GenServer.call(catalog, :hooks)
  end

  @spec tool_definitions(GenServer.server(), keyword()) :: [ToolDefinition.t()]
  def tool_definitions(catalog, opts \\ []) do
    GenServer.call(catalog, {:tool_definitions, opts})
  end

  @spec classify(GenServer.server(), String.t(), [Skill.t()]) ::
          :handler | :activate_skill | :builtin | :subagent | {:module_skill, Skill.t()}
  def classify(catalog, tool_name, activated_skills \\ []) do
    GenServer.call(catalog, {:classify, tool_name, activated_skills})
  end

  @doc """
  Returns `{handler_module, metadata}` for the first kit that declares a handler,
  or `nil` if no handler kit exists.
  """
  @spec handler_config(GenServer.server()) :: {module(), map()} | nil
  def handler_config(catalog) do
    GenServer.call(catalog, :handler_config)
  end

  # -------------------------------------------------------------------
  # GenServer callbacks
  # -------------------------------------------------------------------

  @impl true
  def init({providers, scope}) do
    permissions = resolve_permissions(scope)
    {:ok, %{providers: providers, scope: scope, permissions: permissions}}
  end

  @impl true
  def handle_call(:list_skills, _from, state) do
    kits = load_all_kits(state.providers)
    skills = filter_authorized_skills(all_skills(kits), state)
    tuples = Enum.map(skills, &{&1.name, &1.description})
    {:reply, tuples, state}
  end

  def handle_call({:get_skill, name}, _from, state) do
    kits = load_all_kits(state.providers)
    result = find_and_authorize_skill(all_skills(kits), name, state)
    {:reply, result, state}
  end

  def handle_call(:list_agents, _from, state) do
    kits = load_all_kits(state.providers)
    agents = Enum.flat_map(kits, & &1.agents)
    {:reply, agents, state}
  end

  def handle_call({:get_agent, name}, _from, state) do
    kits = load_all_kits(state.providers)
    result = find_agent(kits, name)
    {:reply, result, state}
  end

  def handle_call(:root_agent, _from, state) do
    kits = load_all_kits(state.providers)
    root = find_root_agent(kits)
    {:reply, root, state}
  end

  def handle_call(:hooks, _from, state) do
    kits = load_all_kits(state.providers)

    hooks =
      kits
      |> all_skills()
      |> Enum.flat_map(& &1.hooks)

    {:reply, hooks, state}
  end

  def handle_call({:tool_definitions, opts}, _from, state) do
    kits = load_all_kits(state.providers)
    tools = build_tools(kits, state, opts)
    {:reply, tools, state}
  end

  def handle_call({:classify, tool_name, activated_skills}, _from, state) do
    kits = load_all_kits(state.providers)
    result = do_classify(kits, tool_name, activated_skills)
    {:reply, result, state}
  end

  def handle_call(:handler_config, _from, state) do
    kits = load_all_kits(state.providers)
    result = find_handler_config(kits)
    {:reply, result, state}
  end

  # -------------------------------------------------------------------
  # Provider loading
  # -------------------------------------------------------------------

  defp load_all_kits(providers) do
    Enum.flat_map(providers, &load_provider_kits/1)
  end

  defp load_provider_kits({module, config}) do
    case module.list_kits(config) do
      {:ok, kits} ->
        kits

      {:error, reason} ->
        Logger.warning("Catalog: provider #{inspect(module)} failed: #{inspect(reason)}")
        []
    end
  end

  # -------------------------------------------------------------------
  # Permissions
  # -------------------------------------------------------------------

  defp resolve_permissions(nil), do: nil

  defp resolve_permissions(scope) do
    SkillKit.Scope.permissions(scope)
  rescue
    Protocol.UndefinedError ->
      Logger.warning(
        "Catalog: scope #{inspect(scope)} does not implement SkillKit.Scope protocol"
      )

      []
  end

  # -------------------------------------------------------------------
  # Skills
  # -------------------------------------------------------------------

  defp all_skills(kits) do
    Enum.flat_map(kits, & &1.skills)
  end

  defp filter_authorized_skills(skills, %{permissions: nil}), do: skills

  defp filter_authorized_skills(skills, %{permissions: permissions}) do
    Enum.filter(skills, &Authorization.authorized?(&1, permissions))
  end

  defp find_and_authorize_skill(skills, name, state) do
    case Enum.find(skills, &(&1.name == name)) do
      nil -> {:error, :not_found}
      skill -> authorize_single_skill(skill, state)
    end
  end

  defp authorize_single_skill(skill, %{permissions: nil}), do: {:ok, skill}

  defp authorize_single_skill(skill, %{permissions: permissions}) do
    if Authorization.authorized?(skill, permissions) do
      {:ok, skill}
    else
      {:error, :unauthorized}
    end
  end

  # -------------------------------------------------------------------
  # Agents
  # -------------------------------------------------------------------

  defp find_agent(kits, name) do
    result =
      kits
      |> Enum.flat_map(& &1.agents)
      |> Enum.find(&(&1.name == name))

    resolve_agent(result)
  end

  defp resolve_agent(nil), do: {:error, :not_found}
  defp resolve_agent(agent), do: {:ok, agent}

  defp find_root_agent(kits) do
    kits
    |> Enum.map(& &1.root_agent)
    |> Enum.find(&(&1 != nil))
  end

  # -------------------------------------------------------------------
  # Tool building (matches ToolBuilder exactly)
  # -------------------------------------------------------------------

  defp build_tools(kits, state, opts) do
    subagent = Keyword.get(opts, :subagent, false)
    activated_skills = Keyword.get(opts, :activated_skills, [])

    visible_skills = filter_authorized_skills(all_skills(kits), state)
    all_agents = Enum.flat_map(kits, & &1.agents)

    handler_modules = discover_handler_modules(kits)
    handler_tools = Enum.map(handler_modules, & &1.tool_definition())

    activated_tools =
      activated_skills
      |> Enum.filter(&Code.ensure_loaded?(&1.handler))
      |> Enum.map(&skill_to_tool/1)

    handler_set = MapSet.new(handler_modules)

    filterable_skills =
      Enum.filter(visible_skills, fn skill ->
        MapSet.member?(handler_set, skill.handler) or Code.ensure_loaded?(skill.handler)
      end)

    skill_tool = build_activate_skill_tool(filterable_skills)
    agent_tools = Enum.map(all_agents, &agent_to_tool/1)
    builtins = if subagent, do: builtin_tools(), else: []

    handler_tools ++ activated_tools ++ skill_tool ++ agent_tools ++ builtins
  end

  defp discover_handler_modules(kits) do
    kits
    |> Enum.filter(&Map.has_key?(&1.metadata, :handler))
    |> Enum.map(& &1.metadata.handler)
  end

  defp find_handler_config(kits) do
    case Enum.find(kits, &Map.has_key?(&1.metadata, :handler)) do
      nil -> nil
      kit -> {kit.metadata.handler, kit.metadata}
    end
  end

  defp build_activate_skill_tool([]), do: []

  defp build_activate_skill_tool(skills) do
    skill_names = Enum.map(skills, & &1.name)
    skill_descriptions = Enum.map_join(skills, "\n", &"- #{&1.name}: #{&1.description}")

    [
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
    ]
  end

  defp skill_to_tool(skill) do
    %ToolDefinition{
      name: skill_short_name(skill.name),
      description: skill.description,
      input_schema: %{"type" => "object"}
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

  # -------------------------------------------------------------------
  # Classification (matches ToolBuilder.classifier exactly)
  # -------------------------------------------------------------------

  defp do_classify(kits, tool_name, activated_skills) do
    agent_names =
      kits
      |> Enum.flat_map(& &1.agents)
      |> MapSet.new(& &1.name)

    module_skill_map = Map.new(activated_skills, &{skill_short_name(&1.name), &1})

    cond do
      tool_name == "activate_skill" -> :activate_skill
      MapSet.member?(@subagent_builtins, tool_name) -> :builtin
      MapSet.member?(agent_names, tool_name) -> :subagent
      Map.has_key?(module_skill_map, tool_name) -> {:module_skill, module_skill_map[tool_name]}
      true -> :handler
    end
  end

  @doc """
  Extracts the short name from a namespaced skill name.

  ## Examples

      iex> SkillKit.Catalog.skill_short_name("scheduler:schedule")
      "schedule"

      iex> SkillKit.Catalog.skill_short_name("standalone")
      "standalone"
  """
  @spec skill_short_name(String.t()) :: String.t()
  def skill_short_name(name) do
    case String.split(name, ":", parts: 2) do
      [_ns, short] -> short
      [short] -> short
    end
  end
end
