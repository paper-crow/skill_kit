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

  def child_spec({agent_name, registry} = arg) do
    %{
      id: {__MODULE__, agent_name, registry},
      start: {__MODULE__, :start_link, [arg]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end

  def start_link({agent_name, registry}) do
    DynamicSupervisor.start_link(
      strategy: :one_for_one,
      name: {:via, Registry, {registry, {agent_name, :subagent_supervisor}}}
    )
  end
end
