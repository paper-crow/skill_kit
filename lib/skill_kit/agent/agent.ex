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
          agent_name: String.t(),
          definition: SkillKit.Agent.Definition.t(),
          depth: non_neg_integer(),
          parent_name: String.t() | nil,
          scope: term(),
          sources: [{module(), keyword()}],
          registry: atom()
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
    provider = Map.get(opts, :provider)
    caller = Map.get(opts, :caller)

    server_opts = [kits: kits]
    server_opts = if provider, do: Keyword.put(server_opts, :provider, provider), else: server_opts
    server_opts = if caller, do: Keyword.put(server_opts, :caller, caller), else: server_opts

    children = [
      {Infrastructure, {agent_name, definition, sources, registry}},
      {Core, {agent_name, definition, depth, parent_name, scope, registry, server_opts}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
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
