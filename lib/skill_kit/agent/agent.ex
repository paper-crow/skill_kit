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
        backends: [{SkillKit.Backend.Filesystem, dirs: [...]}],
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
          backends: [{module(), keyword()}],
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
      backends: backends,
      registry: registry
    } = opts

    children = [
      {Infrastructure, {agent_name, definition, backends, registry}},
      {Core, {agent_name, definition, depth, parent_name, scope, registry}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
