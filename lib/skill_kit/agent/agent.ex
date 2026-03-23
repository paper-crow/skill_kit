defmodule SkillKit.Agent do
  @moduledoc """
  Top-level supervisor for an agent.

  Starts two isolated subtrees under `:one_for_one`:
  - `Agent.Infrastructure` — skill registry (crash doesn't affect conversation)
  - `Agent.Core` — mailbox, server, subagent supervisor (`:rest_for_one`)

  ## Starting an agent

      opts = %{
        agent_name: "project-a",
        definition: %Agent.Definition{...},
        depth: 0,
        parent_name: nil,
        scope: %MyApp.Scope{...},
        sources: [{SkillKit.Backend.Filesystem, dirs: [...]}],
        registry: Agent.Registry
      }

      {:ok, pid} = SkillKit.Agent.start_link(opts)
  """

  use Supervisor

  alias SkillKit.Agent.Core
  alias SkillKit.Agent.Infrastructure

  @type opts :: %{
          :agent_name => String.t(),
          :definition => SkillKit.Agent.Definition.t(),
          :depth => non_neg_integer(),
          :parent_name => String.t() | nil,
          :scope => term(),
          :sources => [{module(), keyword()}],
          :registry => atom(),
          optional(:provider) => {module(), keyword()} | nil,
          optional(:caller) => pid() | nil,
          optional(:parent_registry) => atom() | nil
        }

  @spec start_link(opts()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    %{
      agent_name: agent_name,
      definition: definition,
      depth: depth,
      parent_name: parent_name,
      scope: scope,
      sources: sources,
      registry: registry
    } = opts

    kits = load_kits_from_sources(sources)
    definition = inject_required_skills(definition, kits)
    provider = Map.get(opts, :provider)
    caller = Map.get(opts, :caller)

    parent_registry = Map.get(opts, :parent_registry)

    server_opts = [kits: kits, sources: sources]
    server_opts = if provider, do: Keyword.put(server_opts, :provider, provider), else: server_opts
    server_opts = if caller, do: Keyword.put(server_opts, :caller, caller), else: server_opts
    server_opts = if parent_registry, do: Keyword.put(server_opts, :parent_registry, parent_registry), else: server_opts

    children = [
      {Registry, keys: :unique, name: registry},
      {Infrastructure, {agent_name, definition, sources, registry}},
      {Core, {agent_name, definition, depth, parent_name, scope, registry, server_opts}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp inject_required_skills(definition, kits) do
    case definition.skills do
      [] ->
        definition

      skill_names ->
        all_skills = Enum.flat_map(kits, & &1.skills)

        skill_blocks =
          skill_names
          |> Enum.map(fn name -> Enum.find(all_skills, & &1.name == name) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn skill -> "\n\n## #{skill.name}\n\n#{skill.body}" end)
          |> Enum.join()

        %{definition | system_prompt: definition.system_prompt <> skill_blocks}
    end
  end

  defp load_kits_from_sources(sources) do
    Enum.flat_map(sources, fn {mod, config} ->
      case mod.load_kits(config) do
        {:ok, kits} -> kits
        {:error, _} -> []
      end
    end)
  end
end
