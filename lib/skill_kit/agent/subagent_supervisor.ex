defmodule SkillKit.Agent.SubagentSupervisor do
  @moduledoc """
  DynamicSupervisor for subagents (skills and agent-subagents).

  Registered in Agent.Registry under `{agent_name, :subagent_supervisor}`.
  Agent.Server looks it up to spawn subagent children.

  Uses `:via` naming rather than `Registry.register` in init because
  DynamicSupervisor.init/1 timing with Registry.register is fragile
  on restarts. GenServers (Mailbox, Server) use Registry.register
  in init which is reliable for GenServer processes.
  """

  use DynamicSupervisor

  def start_link(%SkillKit.Agent{} = agent) do
    DynamicSupervisor.start_link(__MODULE__, :ok,
      name: {:via, Registry, {agent.registry, {agent.name, :subagent_supervisor}}}
    )
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
