defmodule SkillKit.Agent.Supervisor do
  @moduledoc """
  Top-level supervisor for an agent.

  Starts three children under `:one_for_one`:
  - `Registry` — process registry for agent components
  - `SkillKit.Catalog` — provider aggregation, authorization, tool definitions
  - `Agent.Core` — mailbox, server, subagent supervisor (`:rest_for_one`)

  Receives a `%SkillKit.Agent{}` struct directly.
  """

  use Supervisor

  alias SkillKit.Agent.Core

  @spec start_link(SkillKit.Agent.t()) :: Supervisor.on_start()
  def start_link(%SkillKit.Agent{} = agent) do
    Supervisor.start_link(__MODULE__, agent)
  end

  @impl true
  def init(%SkillKit.Agent{} = agent) do
    children = [
      {Registry, keys: :unique, name: agent.registry},
      {SkillKit.Catalog,
       name: {:via, Registry, {agent.registry, {agent.name, :catalog}}},
       tools: agent.tools,
       skills: agent.skills,
       scope: agent.scope},
      {Core, agent}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
