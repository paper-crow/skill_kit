defmodule SkillKit.Catalog do
  @moduledoc """
  Aggregates kits from multiple providers and exposes skills, agents,
  tool definitions, and tool call classification.

  ## Always Fresh

  Every query calls providers via `list_kits/1` — there is no internal
  caching. This ensures the catalog always reflects the current state of
  providers (important for Kit.Memory and other dynamic sources).
  """

  use GenServer

  require Logger

  alias SkillKit.Agent
  alias SkillKit.Authorization
  alias SkillKit.Skill
  alias SkillKit.Tool

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

  @spec list_skills(GenServer.server() | Agent.t()) :: [{String.t(), String.t()}]
  def list_skills(agent_or_catalog) do
    GenServer.call(server_ref(agent_or_catalog), :list_skills)
  end

  @spec get_skill(GenServer.server() | Agent.t(), String.t()) ::
          {:ok, Skill.t()} | {:error, :not_found | :unauthorized}
  def get_skill(agent_or_catalog, name) do
    GenServer.call(server_ref(agent_or_catalog), {:get_skill, name})
  end

  @spec list_agents(GenServer.server() | Agent.t()) :: [Agent.t()]
  def list_agents(agent_or_catalog) do
    GenServer.call(server_ref(agent_or_catalog), :list_agents)
  end

  @spec get_agent(GenServer.server() | Agent.t(), String.t()) ::
          {:ok, Agent.t()} | {:error, :not_found}
  def get_agent(agent_or_catalog, name) do
    GenServer.call(server_ref(agent_or_catalog), {:get_agent, name})
  end

  @spec agent(GenServer.server() | Agent.t()) :: Agent.t() | nil
  def agent(agent_or_catalog) do
    GenServer.call(server_ref(agent_or_catalog), :agent)
  end

  @spec list_hooks(GenServer.server() | Agent.t(), SkillKit.Hook.event()) :: [SkillKit.Hook.t()]
  def list_hooks(agent_or_catalog, event) do
    GenServer.call(server_ref(agent_or_catalog), {:list_hooks, event})
  end

  @spec tool_definitions(GenServer.server() | Agent.t(), keyword()) :: [Tool.t()]
  def tool_definitions(agent_or_catalog, opts \\ []) do
    GenServer.call(server_ref(agent_or_catalog), {:tool_definitions, opts})
  end

  @spec classify(GenServer.server() | Agent.t(), String.t()) ::
          :tool | :activate_skill | :subagent
  def classify(agent_or_catalog, tool_name) do
    GenServer.call(server_ref(agent_or_catalog), {:classify, tool_name})
  end

  @doc """
  Returns `{tool_module, metadata}` for the first kit that declares a tool,
  or `nil` if no tool kit exists.
  """
  @spec tool_config(GenServer.server() | Agent.t()) :: {module(), map()} | nil
  def tool_config(agent_or_catalog) do
    GenServer.call(server_ref(agent_or_catalog), :tool_config)
  end

  # -------------------------------------------------------------------
  # Server resolution
  # -------------------------------------------------------------------

  defp server_ref(%Agent{} = agent) do
    {:via, Registry, {agent.registry, {agent.name, :catalog}}}
  end

  defp server_ref(server), do: server

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
    agents = Enum.flat_map(kits, & &1.subagents)
    {:reply, agents, state}
  end

  def handle_call({:get_agent, name}, _from, state) do
    kits = load_all_kits(state.providers)
    result = find_subagent(kits, name)
    {:reply, result, state}
  end

  def handle_call(:agent, _from, state) do
    kits = load_all_kits(state.providers)
    agent = find_agent_definition(kits)
    {:reply, agent, state}
  end

  def handle_call({:list_hooks, event}, _from, state) do
    kits = load_all_kits(state.providers)

    hooks =
      kits
      |> all_skills()
      |> Enum.flat_map(& &1.hooks)
      |> Enum.filter(&(&1.event == event))

    {:reply, hooks, state}
  end

  def handle_call({:tool_definitions, opts}, _from, state) do
    kits = load_all_kits(state.providers)
    tools = build_tools(kits, state, opts)
    {:reply, tools, state}
  end

  def handle_call({:classify, tool_name}, _from, state) do
    kits = load_all_kits(state.providers)
    result = do_classify(kits, tool_name)
    {:reply, result, state}
  end

  # Backward compat — ignore activated_skills
  def handle_call({:classify, tool_name, _activated_skills}, _from, state) do
    kits = load_all_kits(state.providers)
    result = do_classify(kits, tool_name)
    {:reply, result, state}
  end

  def handle_call(:tool_config, _from, state) do
    kits = load_all_kits(state.providers)
    result = find_tool_config(kits)
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

  defp find_subagent(kits, name) do
    result =
      kits
      |> Enum.flat_map(& &1.subagents)
      |> Enum.find(&(&1.name == name))

    resolve_subagent(result)
  end

  defp resolve_subagent(nil), do: {:error, :not_found}
  defp resolve_subagent(agent), do: {:ok, agent}

  defp find_agent_definition(kits) do
    kits
    |> Enum.map(& &1.agent)
    |> Enum.find(&(&1 != nil))
  end

  # -------------------------------------------------------------------
  # Tool building
  # -------------------------------------------------------------------

  defp build_tools(kits, state, _opts) do
    visible_skills = filter_authorized_skills(all_skills(kits), state)
    all_agents = Enum.flat_map(kits, & &1.subagents)

    tool_modules = discover_tool_modules(kits)
    tool_defs = Enum.map(tool_modules, & &1.definition())

    tool_set = MapSet.new(tool_modules)

    filterable_skills =
      Enum.filter(visible_skills, fn skill ->
        MapSet.member?(tool_set, skill.tool) or Code.ensure_loaded?(skill.tool)
      end)

    skill_tool = build_activate_skill_tool(filterable_skills)
    agent_tools = Enum.map(all_agents, &agent_to_tool/1)

    tool_defs ++ skill_tool ++ agent_tools
  end

  defp discover_tool_modules(kits) do
    kits
    |> Enum.filter(&Map.has_key?(&1.metadata, :tool))
    |> Enum.map(& &1.metadata.tool)
  end

  defp find_tool_config(kits) do
    case Enum.find(kits, &Map.has_key?(&1.metadata, :tool)) do
      nil -> nil
      kit -> {kit.metadata.tool, kit.metadata}
    end
  end

  defp build_activate_skill_tool([]), do: []

  defp build_activate_skill_tool(skills) do
    skill_names = Enum.map(skills, & &1.name)
    skill_descriptions = Enum.map_join(skills, "\n", &"- #{&1.name}: #{&1.description}")

    [
      %Tool{
        name: "activate_skill",
        description:
          "Activate a skill to handle the current task. The skill runs with full " <>
            "conversation context in an isolated agent. Available skills:\n#{skill_descriptions}",
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
    ]
  end

  defp agent_to_tool(%Agent{name: name, description: description}) do
    %Tool{
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

  # -------------------------------------------------------------------
  # Classification
  # -------------------------------------------------------------------

  defp do_classify(kits, tool_name) do
    agent_names =
      kits
      |> Enum.flat_map(& &1.subagents)
      |> MapSet.new(& &1.name)

    cond do
      tool_name == "activate_skill" -> :activate_skill
      MapSet.member?(agent_names, tool_name) -> :subagent
      true -> :tool
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
